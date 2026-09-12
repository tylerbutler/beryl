import app_test_helper
import beryl
import beryl/channel
import beryl/group
import beryl/overload
import beryl/snapshot
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import channel_dispatch_helper as helper
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import test_helper

@external(erlang, "beryl_test_process_ffi", "with_suspended")
fn with_suspended(pid: process.Pid, action: fn() -> a) -> a

pub fn rejected_index_closes_without_join_success_or_later_effects_test() -> Nil {
  let entered = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config() |> beryl.with_router_queue_limits(limits(1, 4096)),
      init: app_test_helper.accepting_init,
      update: fn(model, input) {
        case input {
          socket.Join("room:reject", _, ref) -> {
            let release = process.new_subject()
            process.send(entered, release)
            process.receive_forever(release)
            socket.Next(model, [
              socket.AcceptJoin(ref, option.None),
              socket.Push("room:reject", "unexpected", json.null()),
            ])
          }
          _ -> app_test_helper.accepting_update(model, input)
        }
      },
    )
  let healthy = helper.connect(sockets, "healthy")
  helper.join(sockets, "healthy", "room:a", "j", "r")
  let _ = helper.recv(healthy)
  test_helper.wait_until(
    fn() {
      let assert Ok(queue) = snapshot.queue(sockets)
      queue.items == 0
    },
    1000,
    5,
  )
  let frames = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(sockets)
  let assert Ok(Nil) =
    transport.admit_socket(
      sockets:,
      owner:,
      socket_id: "rejected",
      send: fn(frame) {
        process.send(frames, frame)
        Ok(Nil)
      },
      send_binary: fn(_) { Ok(Nil) },
      codec: option.None,
      seed: socket.empty_seed(),
      close: fn() { process.send(closed, Nil) },
    )
  helper.join(sockets, "rejected", "room:reject", "j", "r")
  let assert Ok(release) = process.receive(entered, 1000)
  test_helper.wait_until(
    fn() {
      let assert Ok(queue) = snapshot.queue(sockets)
      queue.items == 0
    },
    1000,
    5,
  )
  with_suspended(owner, fn() {
    beryl.broadcast(sockets, "room:a", "queued", json.null())
    |> should.equal(Ok(Nil))
    process.send(release, Nil)
    process.receive(closed, 1000) |> should.equal(Ok(Nil))
  })
  helper.recv(healthy) |> string.contains("queued") |> should.be_true
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.connected_sockets(current) == 1
    },
    1000,
    5,
  )
  app_test_helper.recv_none(frames)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

@external(erlang, "beryl_test_process_ffi", "mailbox_length")
fn mailbox_length(pid: process.Pid) -> Int

@external(erlang, "beryl_test_process_ffi", "stale_lifecycle_signals")
fn stale_lifecycle_signals(
  router: process.Pid,
  id: String,
  old_actor: process.Pid,
) -> Nil

pub fn abandoned_admission_stops_blocked_initializer_test() -> Nil {
  list.each([True, False], fn(kill_caller) {
    let entered = process.new_subject()
    let assert Ok(sockets) =
      app_test_helper.start_app(
        config(),
        init: fn(_) {
          process.send(entered, process.self())
          let _ = process.receive_forever(process.new_subject())
          #(Nil, [])
        },
        update: app_test_helper.accepting_update,
      )
    let assert Ok(owner) = transport.runtime_pid(sockets)
    let result = process.new_subject()
    let caller =
      process.spawn_unlinked(fn() {
        let admitted =
          transport.admit_socket(
            sockets:,
            owner:,
            socket_id: "abandoned",
            send: fn(_) { Ok(Nil) },
            send_binary: fn(_) { Ok(Nil) },
            codec: option.None,
            seed: socket.empty_seed(),
            close: fn() { Nil },
          )
        process.send(result, admitted)
      })
    let assert Ok(child) = process.receive(entered, 1000)
    let monitor = process.monitor(child)
    case kill_caller {
      True -> process.kill(caller)
      False -> process.receive(result, 2000) |> should.equal(Ok(Error(Nil)))
    }
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(1000)
    test_helper.wait_until(
      fn() {
        let assert Ok(current) = snapshot.get(sockets)
        snapshot.connected_sockets(current) == 0
      },
      1000,
      5,
    )
    test_helper.wait_until(
      fn() {
        let assert Ok(queue) = snapshot.queue(sockets)
        queue.items == 0
      },
      1000,
      5,
    )
    beryl.stop(sockets) |> should.equal(Ok(Nil))
  })
}

pub fn stale_index_and_close_signals_do_not_change_replacement_test() -> Nil {
  let actors = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config(),
      init: fn(_) {
        process.send(actors, process.self())
        #(Nil, [])
      },
      update: app_test_helper.accepting_update,
    )
  let old_frames = helper.connect(sockets, "reused")
  let assert Ok(old_actor) = process.receive(actors, 1000)
  helper.join(sockets, "reused", "room:a", "j", "r")
  let _ = helper.recv(old_frames)
  transport.socket_disconnected(sockets, "reused")
  let _ = helper.recv(old_frames)
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.connected_sockets(current) == 0
    },
    1000,
    5,
  )
  let frames = helper.connect(sockets, "reused")
  let assert Ok(_) = process.receive(actors, 1000)
  helper.join(sockets, "reused", "room:a", "new", "r")
  let _ = helper.recv(frames)
  let assert Ok(router) = transport.runtime_pid(sockets)
  stale_lifecycle_signals(router, "reused", old_actor)
  beryl.broadcast(sockets, "room:a", "still_joined", json.null())
  |> should.equal(Ok(Nil))
  helper.recv(frames) |> string.contains("still_joined") |> should.be_true
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn shutdown_sends_one_terminal_request_per_socket_test() -> Nil {
  let entered = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config(),
      init: fn(info) { #(info.socket_id, []) },
      update: fn(id, input) {
        case input {
          socket.Join(_, _, ref) ->
            socket.Next(id, [socket.AcceptJoin(ref, option.None)])
          socket.Closed(..) if id == "blocked" -> {
            let release = process.new_subject()
            process.send(entered, #(process.self(), release))
            process.receive_forever(release)
            socket.Next(id, [])
          }
          _ -> socket.Next(id, [])
        }
      },
    )
  let connections =
    list.map(["blocked", "one", "two", "three", "four", "five"], fn(id) {
      let frames = helper.connect(sockets, id)
      helper.join(sockets, id, "room:a", "j", "r")
      let _ = helper.recv(frames)
      frames
    })
  let stopped = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() { process.send(stopped, beryl.stop(sockets)) })
  let assert Ok(#(owner, release)) = process.receive(entered, 1000)
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.connected_sockets(current) == 1
    },
    1000,
    5,
  )
  list.each(list.repeat(Nil, 1000), fn(_) {
    beryl.stop(sockets) |> should.equal(Error(beryl.NotRunning))
  })
  mailbox_length(owner) |> fn(count) { count <= 3 } |> should.be_true
  process.send(release, Nil)
  process.receive(stopped, 3000) |> should.equal(Ok(Ok(Nil)))
  list.each(connections, fn(frames) {
    helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  })
}

pub fn unanswered_refs_remain_charged_and_close_reclaims_them_test() -> Nil {
  let senders = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config() |> beryl.with_socket_queue_limits(limits(4, 4096)),
      init: fn(info) {
        process.send(senders, info.self)
        #(Nil, [])
      },
      update: app_test_helper.accepting_update,
    )
  let frames = helper.connect(sockets, "refs")
  let assert Ok(sender) = process.receive(senders, 1000)
  helper.join(sockets, "refs", "room:a", "j", "r")
  let _ = helper.recv(frames)
  list.each([1, 2], fn(count) {
    helper.push(sockets, "refs", "room:a", "unanswered", string.inspect(count))
    test_helper.wait_until(
      fn() {
        let assert Ok(current) = socket.queue_snapshot(sender)
        current.items == count
      },
      1000,
      5,
    )
  })
  helper.push(sockets, "refs", "room:a", "unanswered", "third")
  helper.recv(frames) |> string.contains("phx_error") |> should.be_true
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.connected_sockets(current) == 0
    },
    1000,
    5,
  )
  socket.queue_snapshot(sender) |> should.equal(Error(overload.Unavailable))
  let _ = helper.connect(sockets, "refs")
  let assert Ok(replacement) = process.receive(senders, 1000)
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = socket.queue_snapshot(replacement)
      current.items == 0
    },
    1000,
    5,
  )
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn repeated_disconnects_coalesce_while_callback_is_blocked_test() -> Nil {
  let senders = process.new_subject()
  let entered = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config(),
      init: fn(info) {
        process.send(senders, info.self)
        #(Nil, [])
      },
      update: fn(model, input) {
        case input {
          socket.Info(Nil) -> {
            let release = process.new_subject()
            process.send(entered, #(process.self(), release))
            process.receive_forever(release)
            socket.Next(model, [])
          }
          _ -> app_test_helper.accepting_update(model, input)
        }
      },
    )
  let _ = helper.connect(sockets, "closing")
  let assert Ok(sender) = process.receive(senders, 1000)
  socket.notify(sender, Nil) |> should.equal(Ok(Nil))
  let assert Ok(#(owner, release)) = process.receive(entered, 1000)
  list.each(list.repeat(Nil, 10_000), fn(_) {
    transport.socket_disconnected(sockets, "closing")
  })
  mailbox_length(owner) |> fn(count) { count <= 3 } |> should.be_true
  let assert Ok(blocked) = socket.queue_snapshot(sender)
  blocked.items |> should.equal(1)
  socket.notify(sender, Nil) |> should.equal(Error(overload.Closed))
  process.send(release, Nil)
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.connected_sockets(current) == 0
    },
    1000,
    5,
  )
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn saturated_router_rejects_admission_and_both_transport_frame_kinds_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config() |> beryl.with_router_queue_limits(limits(1, 4096)),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let connections =
    list.map([transport.Mist, transport.Ewe], fn(kind) {
      let assert Ok(permit) =
        transport.acquire_connection_slot(sockets, "127.0.0.1")
      let #(state, _) =
        server.init_connection(
          sockets:,
          seed: socket.empty_seed(),
          connection_permit: permit,
          base_selector: process.new_selector(),
          config: server.default_config("/socket"),
          force_close: fn() { Ok(Nil) },
          logger_name: "overload.test",
          telemetry: transport.telemetry(sockets, kind),
          codec: option.None,
        )
      state
    })
  let assert Ok(owner) = transport.runtime_pid(sockets)
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.queue(sockets)
      current.items == 0
    },
    1000,
    5,
  )
  with_suspended(owner, fn() {
    beryl.broadcast(sockets, "room:a", "held", json.null())
    |> should.equal(Ok(Nil))
    beryl.broadcast(sockets, "room:a", "rejected", json.null())
    |> should.equal(Error(overload.Overloaded(overload.RouterQueue)))
    transport.admit_socket(
      sockets:,
      owner:,
      socket_id: "rejected",
      send: fn(_) { Ok(Nil) },
      send_binary: fn(_) { Ok(Nil) },
      codec: option.None,
      seed: socket.empty_seed(),
      close: fn() { Nil },
    )
    |> should.equal(Error(Nil))
    list.each(connections, fn(state) {
      server.handle_text_frame(
        state,
        "[null,\"r\",\"phoenix\",\"heartbeat\",{}]",
      )
      |> should.equal(server.Stop)
      server.handle_binary_frame(state, <<0, 0, 0, 1, 1, "t":utf8, "e":utf8>>)
      |> should.equal(server.Stop)
    })
    let assert Ok(current) = snapshot.queue(sockets)
    current.items |> should.equal(1)
    current.high_items |> should.equal(1)
    current.rejected |> should.equal(6)
  })
  list.each(connections, server.close_connection)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn group_reports_partial_router_admission_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config() |> beryl.with_router_queue_limits(limits(1, 4096)),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "rooms")
  let assert Ok(Nil) = group.add(groups, "rooms", "room:a")
  let assert Ok(Nil) = group.add(groups, "rooms", "room:b")
  let assert Ok(owner) = transport.runtime_pid(sockets)
  with_suspended(owner, fn() {
    group.broadcast(groups, sockets, "rooms", "event", json.null())
    |> should.equal(
      Error(group.BroadcastRejected(
        1,
        overload.Overloaded(overload.RouterQueue),
      )),
    )
  })
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

fn limits(items: Int, bytes: Int) -> overload.Limits {
  let assert Ok(limits) = overload.limits(items:, bytes:)
  limits
}

fn config() -> beryl.Config {
  beryl.config(wire.phoenix_codec())
  |> beryl.with_effect_limits(limits(2, 4096))
}

pub fn oversized_init_is_not_registered_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config(),
      init: fn(_) {
        #(Nil, list.repeat(socket.Push("room:a", "rejected", json.null()), 3))
      },
      update: app_test_helper.accepting_update,
    )
  let assert Ok(owner) = transport.runtime_pid(sockets)
  transport.admit_socket(
    sockets:,
    owner:,
    socket_id: "init",
    send: fn(_) { Ok(Nil) },
    send_binary: fn(_) { Ok(Nil) },
    codec: option.None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Error(Nil))
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn oversized_raw_join_applies_no_prefix_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config(),
      init: app_test_helper.accepting_init,
      update: fn(model, input) {
        case input {
          socket.Join(topic, _, ref) ->
            socket.Next(model, [
              socket.AcceptJoin(ref, option.None),
              socket.Push(topic, "rejected", json.null()),
              socket.Push(topic, "rejected", json.null()),
            ])
          _ -> socket.Next(model, [])
        }
      },
    )
  let frames = helper.connect(sockets, "s1")
  helper.join(sockets, "s1", "room:a", "j", "r")
  helper.recv(frames)
  |> string.contains("\"status\":\"error\"")
  |> should.be_true
  app_test_helper.recv_none(frames)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn oversized_raw_update_applies_no_prefix_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config(),
      init: app_test_helper.accepting_init,
      update: fn(model, input) {
        case input {
          socket.Message(topic, _, _, _) ->
            socket.Next(
              model,
              list.repeat(socket.Push(topic, "rejected", json.null()), 3),
            )
          _ -> app_test_helper.accepting_update(model, input)
        }
      },
    )
  let frames = helper.connect(sockets, "s1")
  helper.join(sockets, "s1", "room:a", "j", "r")
  let _ = helper.recv(frames)
  helper.push(sockets, "s1", "room:a", "oversized", "m")
  helper.recv(frames) |> string.contains("phx_error") |> should.be_true
  app_test_helper.recv_none(frames)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn oversized_worker_join_applies_no_prefix_test() -> Nil {
  let sockets =
    helper.start(config(), [
      channel.handler("room:*", fn(_) {
        channel.accept(Nil)
        |> channel.with_actions(list.repeat(
          channel.push("rejected", json.null()),
          3,
        ))
      }),
    ])
  let frames = helper.connect(sockets, "s1")
  helper.join(sockets, "s1", "room:a", "j", "r")
  helper.recv(frames)
  |> string.contains("\"status\":\"error\"")
  |> should.be_true
  app_test_helper.recv_none(frames)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn worker_join_reuses_its_reserved_report_capacity_test() -> Nil {
  let sockets =
    helper.start(config() |> beryl.with_socket_queue_limits(limits(2, 4096)), [
      channel.handler("room:*", fn(_) {
        channel.accept(Nil)
        |> channel.with_actions([channel.push("ready", json.null())])
      }),
    ])
  let frames = helper.connect(sockets, "s1")
  helper.join(sockets, "s1", "room:a", "j", "r")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  helper.recv(frames) |> string.contains("\"ready\"") |> should.be_true
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn oversized_worker_result_closes_without_applying_prefix_test() -> Nil {
  let sockets =
    helper.start(config(), [
      channel.handler("room:*", fn(_) {
        channel.accept(Nil)
        |> channel.on_message(fn(_, _) {
          channel.next(Nil, [
            channel.push("rejected", json.null()),
            channel.push("too_large", json.string(string.repeat("x", 8192))),
          ])
        })
      }),
    ])
  let frames = helper.connect(sockets, "s1")
  helper.join(sockets, "s1", "room:a", "j", "r")
  let _ = helper.recv(frames)
  helper.push(sockets, "s1", "room:a", "oversized", "m")
  helper.recv(frames) |> string.contains("phx_error") |> should.be_true
  app_test_helper.recv_none(frames)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn oversized_termination_applies_no_prefix_test() -> Nil {
  let sockets =
    helper.start(config(), [
      channel.handler("room:*", fn(_) {
        channel.accept(Nil)
        |> channel.on_terminate(fn(_, _) {
          list.repeat(channel.broadcast("rejected", json.null()), 3)
        })
      }),
    ])
  let frames = helper.connect(sockets, "s1")
  helper.join(sockets, "s1", "room:a", "j", "r")
  let _ = helper.recv(frames)
  helper.leave(sockets, "s1", "room:a", "j", "leave")
  helper.recv(frames) |> string.contains("\"leave\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  app_test_helper.recv_none(frames)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

type Signal {
  Block
  Ping
}

pub fn saturated_worker_rejects_notify_while_sibling_progresses_test() -> Nil {
  let senders = process.new_subject()
  let entered = process.new_subject()
  let finished = process.new_subject()
  let sockets =
    helper.start(config() |> beryl.with_worker_queue_limits(limits(2, 4096)), [
      channel.handler("room:*", fn(context) {
        process.send(senders, context.self)
        channel.accept(Nil)
        |> channel.on_info(fn(_, signal) {
          case signal {
            Block -> {
              let release = process.new_subject()
              process.send(entered, release)
              process.receive_forever(release)
            }
            Ping -> Nil
          }
          process.send(finished, context.topic)
          channel.stay(Nil)
        })
      }),
    ])
  let frames = helper.connect(sockets, "s1")
  helper.join(sockets, "s1", "room:hot", "j1", "r1")
  let _ = helper.recv(frames)
  let assert Ok(hot) = process.receive(senders, 1000)
  channel.notify(hot, Block) |> should.equal(Ok(Nil))
  let assert Ok(release) = process.receive(entered, 1000)
  channel.notify(hot, Ping) |> should.equal(Ok(Nil))
  list.repeat(Nil, 20)
  |> list.each(fn(_) {
    channel.notify(hot, Ping)
    |> should.equal(Error(overload.Overloaded(overload.WorkerQueue)))
  })
  let assert Ok(full) = channel.queue_snapshot(hot)
  full.items |> should.equal(2)
  full.max_items |> should.equal(2)
  full.high_items |> should.equal(2)
  full.rejected |> should.equal(20)
  full.boundary |> should.equal(overload.WorkerQueue)
  test_helper.wait_until(
    fn() {
      let assert Ok(snapshot) = channel.queue_snapshot(hot)
      snapshot.oldest_age_ms > 0
    },
    1000,
    1,
  )
  helper.join(sockets, "s1", "room:healthy", "j2", "r2")
  let _ = helper.recv(frames)
  let assert Ok(healthy) = process.receive(senders, 1000)
  channel.notify(healthy, Ping) |> should.equal(Ok(Nil))
  process.receive(finished, 1000) |> should.equal(Ok("room:healthy"))
  process.send(release, Nil)
  process.receive(finished, 1000) |> should.equal(Ok("room:hot"))
  process.receive(finished, 1000) |> should.equal(Ok("room:hot"))
  test_helper.wait_until(
    fn() {
      let assert Ok(snapshot) = channel.queue_snapshot(hot)
      snapshot.items == 0
    },
    1000,
    1,
  )
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  channel.queue_snapshot(hot) |> should.equal(Error(overload.Unavailable))
  channel.notify(hot, Ping) |> should.equal(Error(overload.Unavailable))
}
