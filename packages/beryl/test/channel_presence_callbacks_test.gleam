import beryl
import beryl/channel
import beryl/presence
import beryl/wire
import channel_dispatch_helper as helper
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/otp/static_supervisor
import gleeunit/should
import test_helper

fn start_presence() -> presence.Presence {
  let assert Ok(handle) = presence.start(presence.default_config("callbacks"))
  handle
}

fn config(handle: presence.Presence) -> beryl.Config {
  beryl.config(wire.phoenix_codec()) |> beryl.with_presence_handle(handle)
}

fn frame(frames: helper.Frames, event: String) -> dynamic.Dynamic {
  let decoder = {
    use actual <- decode.field(3, decode.string)
    use payload <- decode.field(4, decode.dynamic)
    decode.success(#(actual, payload))
  }
  let assert Ok(#(actual, payload)) = json.parse(helper.recv(frames), decoder)
  actual |> should.equal(event)
  payload
}

fn event(trace: process.Subject(presence.Event)) -> presence.Event {
  let assert Ok(event) = process.receive(trace, 1000)
  event
}

fn count(previous: Int, event: presence.Event) -> Int {
  case event {
    presence.Snapshot(entries) -> list.length(entries)
    presence.Changed(joins, leaves) ->
      previous + list.length(joins) - list.length(leaves)
  }
}

fn observer(
  handle: fn(Int, presence.Event) -> channel.Next(Int),
) -> channel.Handler {
  channel.handler("room:*", fn(context: channel.JoinContext(Nil)) {
    channel.notify(context.self, Nil)
    channel.accept(0)
    |> channel.on_presence(handle)
    |> channel.on_info(fn(state, _) {
      channel.next(state, [channel.push("info", json.int(state))])
    })
    |> channel.on_message(fn(state, _) {
      channel.next(state, [channel.push("count", json.int(state))])
    })
  })
}

fn sibling() -> channel.Handler {
  channel.handler("other:*", fn(_) {
    channel.accept(Nil)
    |> channel.on_message(fn(state, _) {
      channel.next(state, [channel.push("pong", json.null())])
    })
  })
}

fn disconnect(channels: beryl.Sockets, frames: helper.Frames) -> Nil {
  helper.disconnect(channels, "s1")
  let _close = frame(frames, "phx_close")
  beryl.stop(channels) |> should.equal(Ok(Nil))
}

pub fn presence_callbacks_receive_roster_and_update_private_state_test() -> Nil {
  let presence = start_presence()
  let first =
    presence.track(presence, "room:a", "alice", "first", json.object([]))
  let trace = process.new_subject()
  let channels =
    helper.start(config(presence), handlers: [
      observer(fn(state, change) {
        process.send(trace, change)
        let next = count(state, change)
        channel.next(next, [channel.push("roster", json.int(next))])
      }),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "join", "1")
  let _reply = frame(frames, "phx_reply")
  frame(frames, "roster") |> decode.run(decode.int) |> should.equal(Ok(1))
  frame(frames, "info") |> decode.run(decode.int) |> should.equal(Ok(1))
  let assert presence.Snapshot([entry]) = event(trace)
  entry.session_id |> should.equal("first")
  presence.count(presence, "room:a") |> should.equal(Ok(1))

  let second =
    presence.track(presence, "room:a", "alice", "second", json.object([]))
  frame(frames, "roster") |> decode.run(decode.int) |> should.equal(Ok(2))
  let assert presence.Changed([entry], []) = event(trace)
  entry.session_id |> should.equal("second")
  let assert Ok(_updated) =
    presence.update(presence, first, json.object([#("away", json.bool(True))]))
  frame(frames, "roster") |> decode.run(decode.int) |> should.equal(Ok(2))
  let assert presence.Changed([_], [_]) = event(trace)
  presence.untrack(presence, second)
  frame(frames, "roster") |> decode.run(decode.int) |> should.equal(Ok(1))
  let assert presence.Changed([], [_]) = event(trace)
  helper.push(channels, "s1", "room:a", "read", "2")
  frame(frames, "count") |> decode.run(decode.int) |> should.equal(Ok(1))
  disconnect(channels, frames)
}

pub fn tracking_and_observing_compose_in_either_builder_order_test() -> Nil {
  list.each([True, False], fn(track_first) {
    let presence = start_presence()
    let trace = process.new_subject()
    let handler =
      channel.handler("room:*", fn(_) {
        let observe = fn(result) {
          channel.on_presence(result, fn(state, change) {
            process.send(trace, change)
            channel.stay(count(state, change))
          })
        }
        let track = fn(result) {
          channel.with_presence(result, key: "alice", meta: json.object([]))
        }
        case track_first {
          True -> channel.accept(0) |> track |> observe
          False -> channel.accept(0) |> observe |> track
        }
      })
    let channels = helper.start(config(presence), handlers: [handler])
    let frames = helper.connect(channels, "s1")
    helper.join(channels, "s1", "room:a", "join", "1")
    let _reply = frame(frames, "phx_reply")
    let _diff = frame(frames, "presence_diff")
    let _snapshot = frame(frames, "presence_state")
    case event(trace) {
      presence.Snapshot([]) -> {
        let assert presence.Changed([entry], []) = event(trace)
        entry.session_id |> should.equal("s1")
      }
      presence.Snapshot([entry]) -> entry.session_id |> should.equal("s1")
      _ -> should.fail()
    }
    process.receive(trace, 50) |> should.be_error
    disconnect(channels, frames)
  })
}

pub fn observation_is_not_triggered_by_wire_events_or_other_topics_test() -> Nil {
  let presence = start_presence()
  let trace = process.new_subject()
  let channels =
    helper.start(config(presence), handlers: [
      observer(fn(state, change) {
        process.send(trace, change)
        channel.stay(count(state, change))
      }),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "join", "1")
  let _reply = frame(frames, "phx_reply")
  let assert presence.Snapshot([]) = event(trace)
  let _info = frame(frames, "info")
  let _other = presence.track(presence, "room:b", "bob", "other", json.null())
  beryl.broadcast(channels, "room:a", "presence_diff", json.object([]))
  let _fake_diff = frame(frames, "presence_diff")
  helper.push(channels, "s1", "room:a", "presence_diff", "2")
  let _count = frame(frames, "count")
  process.receive(trace, 50) |> should.be_error
  disconnect(channels, frames)
}

pub fn missing_presence_rejects_and_rejected_results_stay_rejected_test() -> Nil {
  let trace = process.new_subject()
  let channels =
    helper.start(beryl.config(wire.phoenix_codec()), handlers: [
      observer(fn(state, change) {
        process.send(trace, change)
        channel.stay(state)
      }),
      channel.handler("denied:*", fn(_) {
        channel.reject(json.string("denied"))
        |> channel.on_presence(fn(state, change) {
          process.send(trace, change)
          channel.stay(state)
        })
      }),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "join", "1")
  frame(frames, "phx_reply")
  |> decode.run(decode.at(["status"], decode.string))
  |> should.equal(Ok("error"))
  helper.join(channels, "s1", "denied:a", "join", "2")
  frame(frames, "phx_reply")
  |> decode.run(decode.at(["response"], decode.string))
  |> should.equal(Ok("denied"))
  process.receive(trace, 50) |> should.be_error
  helper.recv_none(frames)
  beryl.stop(channels) |> should.equal(Ok(Nil))
}

fn gate_presence(
  entered: process.Subject(process.Subject(Nil)),
) -> presence.Presence {
  let assert Ok(handle) =
    presence.start(
      presence.default_config("gated_observer")
      |> presence.with_on_diff(fn(diff) {
        case list.contains(presence.diff_topics(diff), "gate") {
          False -> Nil
          True -> {
            let release = process.new_subject()
            process.send(entered, release)
            let assert Ok(Nil) = process.receive(release, 5000)
            Nil
          }
        }
      }),
    )
  handle
}

fn block_presence(handle: presence.Presence) -> Nil {
  let _worker =
    process.spawn_unlinked(fn() {
      let _ref = presence.track(handle, "gate", "gate", "gate", json.null())
      Nil
    })
  Nil
}

pub fn initial_snapshot_precedes_held_message_and_info_callbacks_test() -> Nil {
  let entered = process.new_subject()
  let presence = gate_presence(entered)
  block_presence(presence)
  let assert Ok(release) = process.receive(entered, 1000)
  let channels =
    helper.start(config(presence), handlers: [
      observer(fn(state, change) {
        channel.next(count(state, change), [
          channel.push("initial", json.null()),
        ])
      }),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "join", "1")
  let _reply = frame(frames, "phx_reply")
  helper.push(channels, "s1", "room:a", "read", "2")
  helper.recv_none(frames)
  process.send(release, Nil)
  let _initial = frame(frames, "initial")
  let _info = frame(frames, "info")
  let _count = frame(frames, "count")
  disconnect(channels, frames)
}

pub fn subscription_timeout_closes_topic_and_rejoin_gets_fresh_snapshot_test() -> Nil {
  let entered = process.new_subject()
  let presence = gate_presence(entered)
  block_presence(presence)
  let assert Ok(release) = process.receive(entered, 1000)
  let trace = process.new_subject()
  let channels =
    helper.start(
      config(presence) |> beryl.with_presence_op_timeout(50),
      handlers: [
        observer(fn(state, change) {
          process.send(trace, change)
          channel.stay(count(state, change))
        }),
        sibling(),
      ],
    )
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "old", "1")
  let _reply = frame(frames, "phx_reply")
  let _error = frame(frames, "phx_error")
  process.receive(trace, 0) |> should.be_error
  process.send(release, Nil)
  let _barrier = presence.track(presence, "barrier", "x", "x", json.null())
  helper.join(channels, "s1", "room:a", "new", "2")
  let _reply = frame(frames, "phx_reply")
  let assert presence.Snapshot([]) = event(trace)
  let _info = frame(frames, "info")
  helper.recv_none(frames)
  disconnect(channels, frames)
}

pub fn source_exit_closes_only_observing_topics_test() -> Nil {
  let presence = start_presence()
  let trace = process.new_subject()
  let channels =
    helper.start(config(presence), handlers: [
      observer(fn(state, change) {
        process.send(trace, change)
        channel.stay(state)
      }),
      sibling(),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "observed", "1")
  let _reply = frame(frames, "phx_reply")
  let assert presence.Snapshot([]) = event(trace)
  let _info = frame(frames, "info")
  helper.join(channels, "s1", "other:a", "other", "2")
  let _reply = frame(frames, "phx_reply")
  test_helper.kill_presence(presence)
  let _error = frame(frames, "phx_error")
  helper.push(channels, "s1", "other:a", "ping", "3")
  let _pong = frame(frames, "pong")
  disconnect(channels, frames)
}

pub fn snapshot_panic_does_not_release_held_callbacks_or_stop_siblings_test() -> Nil {
  let presence = start_presence()
  let channels =
    helper.start(config(presence), handlers: [
      observer(fn(_, _) { panic as "presence callback failed" }),
      sibling(),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "observed", "1")
  let _reply = frame(frames, "phx_reply")
  let _error = frame(frames, "phx_error")
  helper.recv_none(frames)
  helper.join(channels, "s1", "other:a", "other", "2")
  let _reply = frame(frames, "phx_reply")
  helper.push(channels, "s1", "other:a", "ping", "3")
  let _pong = frame(frames, "pong")
  let _ref = presence.track(presence, "room:a", "still_alive", "s", json.null())
  disconnect(channels, frames)
}

pub fn slow_observer_overflow_does_not_block_the_presence_actor_test() -> Nil {
  let presence = start_presence()
  let entered = process.new_subject()
  let channels =
    helper.start(config(presence), handlers: [
      observer(fn(state, _) {
        let release = process.new_subject()
        process.send(entered, release)
        let assert Ok(Nil) = process.receive(release, 5000)
        channel.stay(state)
      }),
      sibling(),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "observed", "1")
  let _reply = frame(frames, "phx_reply")
  let assert Ok(release) = process.receive(entered, 1000)
  list.each(list.repeat(Nil, 65), fn(_) {
    let _ref = presence.track(presence, "room:a", "alice", "s", json.null())
    Nil
  })
  let assert Ok(owner) = process.subject_owner(presence.subject(presence))
  test_helper.monitor_count(owner) |> should.equal(0)
  // The socket can serve another worker while the observer is blocked.
  helper.join(channels, "s1", "other:a", "other", "2")
  process.send(release, Nil)
  let first = helper.recv(frames)
  let second = helper.recv(frames)
  let decoder = {
    use event <- decode.field(3, decode.string)
    decode.success(event)
  }
  let received =
    list.map([first, second], fn(raw) {
      let assert Ok(event) = json.parse(raw, decoder)
      event
    })
  list.contains(received, "phx_error") |> should.be_true
  list.contains(received, "phx_reply") |> should.be_true
  helper.push(channels, "s1", "other:a", "ping", "3")
  let _pong = frame(frames, "pong")
  disconnect(channels, frames)
}

pub fn callback_close_and_worker_death_remove_subscriptions_test() -> Nil {
  let presence = start_presence()
  let workers = process.new_subject()
  let trace = process.new_subject()
  let handler =
    channel.handler("room:*", fn(_) {
      process.send(workers, process.self())
      channel.accept(Nil)
      |> channel.on_presence(fn(state, change) {
        process.send(trace, change)
        case change {
          presence.Snapshot(_) -> channel.stay(state)
          presence.Changed(_, _) -> channel.close([])
        }
      })
    })
  let channels = helper.start(config(presence), handlers: [handler])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "old", "1")
  let _reply = frame(frames, "phx_reply")
  let assert Ok(_old_worker) = process.receive(workers, 1000)
  let assert presence.Snapshot([]) = event(trace)
  let _ref = presence.track(presence, "room:a", "alice", "s", json.null())
  let assert presence.Changed([_], []) = event(trace)
  let _close = frame(frames, "phx_close")
  let assert Ok(owner) = process.subject_owner(presence.subject(presence))
  test_helper.wait_until(
    fn() { test_helper.monitor_count(owner) == 0 },
    1000,
    10,
  )
  helper.join(channels, "s1", "room:a", "new", "2")
  let _reply = frame(frames, "phx_reply")
  let assert Ok(worker) = process.receive(workers, 1000)
  let assert presence.Snapshot([_]) = event(trace)
  process.kill(worker)
  let _error = frame(frames, "phx_error")
  test_helper.wait_until(
    fn() { test_helper.monitor_count(owner) == 0 },
    1000,
    10,
  )
  beryl.stop(channels) |> should.equal(Ok(Nil))
}

pub fn snapshot_credit_waits_for_its_presence_effects_test() -> Nil {
  let entered = process.new_subject()
  let assert Ok(presence) =
    presence.start(
      presence.default_config("effect_credit")
      |> presence.with_on_diff(fn(diff) {
        case presence.diff_joins(diff, "room:a") {
          [] -> Nil
          _ -> {
            let release = process.new_subject()
            process.send(entered, release)
            let assert Ok(Nil) = process.receive(release, 5000)
            Nil
          }
        }
      }),
    )
  let changes = process.new_subject()
  let channels =
    helper.start(config(presence), handlers: [
      observer(fn(state, change) {
        process.send(changes, change)
        case change {
          presence.Snapshot(_) ->
            channel.next(state, [
              channel.presence_track("alice", json.object([])),
              channel.push("tracked", json.null()),
            ])
          presence.Changed(_, _) -> channel.stay(count(state, change))
        }
      }),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "observed", "1")
  let _reply = frame(frames, "phx_reply")
  let assert presence.Snapshot([]) = event(changes)
  let assert Ok(release) = process.receive(entered, 1000)
  helper.recv_none(frames)
  process.receive(changes, 0) |> should.be_error
  process.send(release, Nil)
  let _wire_diff = frame(frames, "presence_diff")
  let _tracked = frame(frames, "tracked")
  let _info = frame(frames, "info")
  let assert presence.Changed([_], []) = event(changes)
  helper.push(channels, "s1", "room:a", "count", "2")
  frame(frames, "count") |> decode.run(decode.int) |> should.equal(Ok(1))
  disconnect(channels, frames)
}

pub fn source_restart_requires_rejoin_even_with_a_stable_handle_test() -> Nil {
  let #(presence, specification) =
    presence.child_spec(presence.default_config("restart"))
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(specification)
    |> static_supervisor.start()
  let assert Ok(original) = process.subject_owner(presence.subject(presence))
  let trace = process.new_subject()
  let channels =
    helper.start(config(presence), handlers: [
      observer(fn(state, change) {
        process.send(trace, change)
        channel.stay(count(state, change))
      }),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "old", "1")
  let _reply = frame(frames, "phx_reply")
  let assert presence.Snapshot([]) = event(trace)
  let _info = frame(frames, "info")
  process.kill(original)
  let _error = frame(frames, "phx_error")
  test_helper.wait_until(
    fn() {
      case process.subject_owner(presence.subject(presence)) {
        Ok(pid) -> pid != original
        Error(Nil) -> False
      }
    },
    1000,
    10,
  )
  let _ref = presence.track(presence, "room:a", "new", "new", json.object([]))
  process.receive(trace, 50) |> should.be_error
  helper.join(channels, "s1", "room:a", "new", "2")
  let _reply = frame(frames, "phx_reply")
  let assert presence.Snapshot([entry]) = event(trace)
  entry.key |> should.equal("new")
  let _info = frame(frames, "info")
  disconnect(channels, frames)
}
