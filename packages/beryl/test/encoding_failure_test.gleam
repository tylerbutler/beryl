import app_test_helper as helper
import beryl
import beryl/channel
import beryl/overload
import beryl/presence
import beryl/snapshot
import beryl/socket
import beryl/transport
import beryl/wire
import beryl/wire/codec
import channel_dispatch_helper
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import test_helper

type Failure {
  ReplyFailure
  PushFailure
  HeartbeatFailure
  CloseFailure
  ErrorFailure
  BinaryReply
  BinaryPush
}

type System {
  System(
    sockets: beryl.Sockets,
    closed: process.Subject(socket.StopReason),
    calls: process.Subject(String),
    senders: process.Subject(socket.Sender(Nil)),
    releases: process.Subject(overload.Occupancy),
  )
}

fn rejected() -> codec.EncodeError {
  codec.EncodingRejected("fixture rejection")
}

fn fallible_codec(
  failure: Failure,
  calls: process.Subject(String),
) -> codec.Codec {
  codec.new(
    decode_text: wire.decode_message,
    encode_reply: fn(join_ref, ref, topic, status, payload) {
      process.send(calls, "reply")
      case failure {
        ReplyFailure if ref == Some("fail") -> Error(rejected())
        BinaryReply ->
          wire.binary_reply(join_ref, ref, topic, status, <<>>)
          |> result.map_error(wire.binary_encode_error_to_encode_error)
        ReplyFailure
        | PushFailure
        | HeartbeatFailure
        | CloseFailure
        | ErrorFailure
        | BinaryPush ->
          Ok(wire.reply_json(join_ref, ref, topic, status, payload))
      }
    },
    encode_push: fn(topic, event, payload) {
      process.send(calls, "push:" <> event)
      case failure {
        PushFailure if event == "fail" -> Error(rejected())
        BinaryPush ->
          wire.binary_push(None, topic, event, <<>>)
          |> result.map_error(wire.binary_encode_error_to_encode_error)
        ReplyFailure
        | PushFailure
        | HeartbeatFailure
        | CloseFailure
        | ErrorFailure
        | BinaryReply -> Ok(wire.push(topic, event, payload))
      }
    },
    encode_heartbeat_reply: fn(ref) {
      process.send(calls, "heartbeat")
      case failure {
        HeartbeatFailure -> Error(rejected())
        ReplyFailure
        | PushFailure
        | CloseFailure
        | ErrorFailure
        | BinaryReply
        | BinaryPush -> Ok(wire.heartbeat_reply(ref))
      }
    },
  )
  |> codec.with_close_encoder(fn(join_ref, topic) {
    process.send(calls, "close")
    case failure {
      CloseFailure -> Error(rejected())
      ReplyFailure
      | PushFailure
      | HeartbeatFailure
      | ErrorFailure
      | BinaryReply
      | BinaryPush -> Ok(wire.channel_close(join_ref, topic))
    }
  })
  |> codec.with_error_encoder(fn(join_ref, topic) {
    process.send(calls, "error")
    case failure {
      ErrorFailure -> Error(rejected())
      ReplyFailure
      | PushFailure
      | HeartbeatFailure
      | CloseFailure
      | BinaryReply
      | BinaryPush -> Ok(wire.channel_error(join_ref, topic))
    }
  })
}

fn start(failure: Failure, handle: presence.Presence) -> System {
  let closed = process.new_subject()
  let calls = process.new_subject()
  let senders = process.new_subject()
  let releases = process.new_subject()
  let assert Ok(sockets) =
    helper.start_app(
      beryl.config(fallible_codec(failure, calls))
        |> beryl.with_presence_handle(handle)
        |> beryl.with_telemetry,
      init: fn(info) {
        process.send(senders, info.self)
        #(info.self, [])
      },
      update: fn(sender, input) {
        case input {
          socket.Join("room:reject", _, reference) ->
            socket.Next(sender, [socket.RejectJoin(reference, json.null())])
          socket.Join(_, _, reference) ->
            socket.Next(sender, [socket.AcceptJoin(reference, None)])
          socket.Message(topic, "reply", _, Some(reference)) ->
            socket.Next(sender, [
              socket.Push(topic, "prefix", json.null()),
              socket.ReplyOk(reference, json.null()),
              socket.Push(topic, "suffix", json.null()),
              socket.Broadcast(topic, "suffix", json.null()),
              socket.PresenceTrack(topic, "suffix", json.null()),
            ])
          socket.Message(_, "reply_error", _, Some(reference)) ->
            socket.Next(sender, [socket.ReplyError(reference, json.null())])
          socket.Message(topic, "push", _, _) ->
            socket.Next(sender, [
              socket.Push(topic, "prefix", json.null()),
              socket.Push(topic, "fail", json.null()),
              socket.Push(topic, "suffix", json.null()),
            ])
          socket.Message(topic, "broadcast", _, _) ->
            socket.Next(sender, [
              socket.Broadcast(topic, "fail", json.null()),
              socket.Broadcast(topic, "suffix", json.null()),
            ])
          socket.Message(topic, "presence", _, _) ->
            socket.Next(sender, [
              socket.PresenceTrack(topic, "tracked", json.null()),
              socket.Push(topic, "fail", json.null()),
              socket.PresenceTrack(topic, "suffix", json.null()),
            ])
          socket.Message(_, "stop", _, _) ->
            socket.Stop(socket.Errored("fixture stop"))
          socket.Message(topic, "kick", _, _) ->
            socket.Next(sender, [socket.KickTopic(topic)])
          socket.Closed(_, reason) -> {
            process.send(closed, reason)
            let assert Ok(current) = socket.queue_snapshot(sender)
            process.send(releases, current)
            socket.Next(sender, [])
          }
          socket.Message(..) | socket.Binary(..) | socket.Info(..) ->
            socket.Next(sender, [])
        }
      },
    )
  System(sockets:, closed:, calls:, senders:, releases:)
}

fn start_presence() -> presence.Presence {
  let assert Ok(handle) =
    presence.default_config("encoding-failure-test")
    |> presence.start()
  handle
}

fn connect(
  system: System,
  socket_id: String,
  active_codec: Option(codec.Codec),
  closed: process.Subject(Nil),
) -> process.Subject(codec.Frame) {
  let frames = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(system.sockets)
  transport.admit_socket(
    system.sockets,
    owner: owner,
    socket_id: socket_id,
    send: fn(text) {
      process.send(frames, codec.TextFrame(text))
      Ok(Nil)
    },
    send_binary: fn(bytes) {
      process.send(frames, codec.BinaryFrame(bytes))
      Ok(Nil)
    },
    codec: active_codec,
    seed: socket.empty_seed(),
    close: fn() { process.send(closed, Nil) },
  )
  |> should.equal(Ok(Nil))
  frames
}

fn receive_frame(frames: process.Subject(codec.Frame)) -> codec.Frame {
  let assert Ok(frame) = process.receive(frames, 1000)
  frame
}

fn joined(system: System, frames: process.Subject(codec.Frame)) -> Nil {
  helper.join(system.sockets, "failed", "room:a", "join", "join")
  let _ = receive_frame(frames)
  process.receive(system.calls, 1000) |> should.equal(Ok("reply"))
}

fn await_removed(system: System, close: process.Subject(Nil)) -> Nil {
  process.receive(close, 2000) |> should.equal(Ok(Nil))
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(system.sockets)
      snapshot.connected_sockets(current) == 0
    },
    2000,
    5,
  )
  process.receive(close, 10) |> should.equal(Error(Nil))
}

pub fn failed_reply_aborts_suffix_and_reclaims_other_references_test() -> Nil {
  let handle = start_presence()
  let system = start(ReplyFailure, handle)
  let close = process.new_subject()
  let frames = connect(system, "failed", None, close)
  let assert Ok(sender) = process.receive(system.senders, 1000)
  joined(system, frames)
  helper.push(system.sockets, "failed", "room:a", "stash", "pending")
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = socket.queue_snapshot(sender)
      current.items == 1
    },
    1000,
    5,
  )
  helper.push(system.sockets, "failed", "room:a", "reply", "fail")
  receive_frame(frames)
  |> should.equal(wire.push("room:a", "prefix", json.null()))
  await_removed(system, close)
  process.receive(system.closed, 1000)
  |> should.equal(Ok(socket.EncodingFailed(rejected())))
  let assert Ok(released) = process.receive(system.releases, 1000)
  // Only this update's input reservation remains during Closed.
  released.items |> should.equal(1)
  process.receive(system.calls, 1000) |> should.equal(Ok("push:prefix"))
  process.receive(system.calls, 1000) |> should.equal(Ok("reply"))
  process.receive(system.calls, 10) |> should.equal(Error(Nil))
  process.receive(frames, 10) |> should.equal(Error(Nil))
  presence.list(handle, "room:a") |> should.equal(Ok([]))
  socket.queue_snapshot(sender) |> should.equal(Error(overload.Unavailable))
  let replacement = connect(system, "failed", None, close)
  let assert Ok(replacement_sender) = process.receive(system.senders, 1000)
  joined(system, replacement)
  let assert Ok(empty) = socket.queue_snapshot(replacement_sender)
  empty.items |> should.equal(0)
  beryl.stop(system.sockets) |> should.equal(Ok(Nil))
}

pub fn failed_push_preserves_prefix_and_stops_later_encoders_test() -> Nil {
  let system = start(PushFailure, start_presence())
  let close = process.new_subject()
  let frames = connect(system, "failed", None, close)
  joined(system, frames)
  helper.push(system.sockets, "failed", "room:a", "push", "event")
  receive_frame(frames)
  |> should.equal(wire.push("room:a", "prefix", json.null()))
  await_removed(system, close)
  process.receive(system.calls, 1000) |> should.equal(Ok("push:prefix"))
  process.receive(system.calls, 1000) |> should.equal(Ok("push:fail"))
  process.receive(system.calls, 10) |> should.equal(Error(Nil))
  process.receive(frames, 10) |> should.equal(Error(Nil))
  beryl.stop(system.sockets) |> should.equal(Ok(Nil))
}

pub fn failed_heartbeat_closes_without_retry_or_fallback_test() -> Nil {
  let system = start(HeartbeatFailure, start_presence())
  let close = process.new_subject()
  let frames = connect(system, "failed", None, close)
  joined(system, frames)
  helper.route(
    system.sockets,
    "failed",
    "[null,\"heartbeat\",\"phoenix\",\"heartbeat\",{}]",
  )
  await_removed(system, close)
  process.receive(system.closed, 1000)
  |> should.equal(Ok(socket.EncodingFailed(rejected())))
  process.receive(system.calls, 1000) |> should.equal(Ok("heartbeat"))
  process.receive(system.calls, 10) |> should.equal(Error(Nil))
  process.receive(frames, 10) |> should.equal(Error(Nil))
  beryl.stop(system.sockets) |> should.equal(Ok(Nil))
}

pub fn failed_join_and_rejection_replies_close_before_later_effects_test() -> Nil {
  list.each(["room:a", "room:reject", ""], fn(topic) {
    let system = start(ReplyFailure, start_presence())
    let close = process.new_subject()
    let frames = connect(system, "failed", None, close)
    helper.join(system.sockets, "failed", topic, "join", "fail")
    await_removed(system, close)
    process.receive(system.calls, 1000) |> should.equal(Ok("reply"))
    process.receive(system.calls, 10) |> should.equal(Error(Nil))
    process.receive(frames, 10) |> should.equal(Error(Nil))
    beryl.stop(system.sockets) |> should.equal(Ok(Nil))
  })
}

pub fn failed_error_reply_is_terminal_test() -> Nil {
  let system = start(ReplyFailure, start_presence())
  let close = process.new_subject()
  let frames = connect(system, "failed", None, close)
  joined(system, frames)
  helper.push(system.sockets, "failed", "room:a", "reply_error", "fail")
  await_removed(system, close)
  process.receive(system.closed, 1000)
  |> should.equal(Ok(socket.EncodingFailed(rejected())))
  process.receive(frames, 10) |> should.equal(Error(Nil))
  beryl.stop(system.sockets) |> should.equal(Ok(Nil))
}

pub fn failed_terminal_encoders_finish_cleanup_without_recursion_test() -> Nil {
  list.each([#(CloseFailure, "kick"), #(ErrorFailure, "stop")], fn(test_case) {
    let #(failure, event) = test_case
    let system = start(failure, start_presence())
    let close = process.new_subject()
    let frames = connect(system, "failed", None, close)
    joined(system, frames)
    helper.push(system.sockets, "failed", "room:a", event, "event")
    await_removed(system, close)
    process.receive(system.calls, 1000)
    |> should.equal(
      Ok(case failure {
        CloseFailure -> "close"
        ErrorFailure -> "error"
        ReplyFailure
        | PushFailure
        | HeartbeatFailure
        | BinaryReply
        | BinaryPush -> "unexpected"
      }),
    )
    process.receive(system.calls, 10) |> should.equal(Error(Nil))
    process.receive(frames, 10) |> should.equal(Error(Nil))
    beryl.stop(system.sockets) |> should.equal(Ok(Nil))
  })
}

pub fn binary_metadata_limits_flow_through_public_runtime_test() -> Nil {
  list.each([BinaryReply, BinaryPush], fn(failure) {
    let system = start(failure, start_presence())
    let close = process.new_subject()
    let frames = connect(system, "failed", None, close)
    let accepted = "room:" <> string.repeat("x", 250)
    let rejected = "room:" <> string.repeat("x", 251)
    case failure {
      BinaryReply -> {
        helper.join(system.sockets, "failed", accepted, "join", "join")
        let assert codec.BinaryFrame(_) = receive_frame(frames)
        helper.join(system.sockets, "failed", rejected, "join2", "join2")
      }
      BinaryPush -> {
        helper.join(system.sockets, "failed", accepted, "join", "join")
        let _ = receive_frame(frames)
        helper.push(system.sockets, "failed", accepted, "push", "event")
        let assert codec.BinaryFrame(_) = receive_frame(frames)
        let assert codec.BinaryFrame(_) = receive_frame(frames)
        let assert codec.BinaryFrame(_) = receive_frame(frames)
        helper.join(system.sockets, "failed", rejected, "join2", "join2")
        let _ = receive_frame(frames)
        helper.push(system.sockets, "failed", rejected, "push", "event2")
      }
      ReplyFailure
      | PushFailure
      | HeartbeatFailure
      | CloseFailure
      | ErrorFailure -> panic as "unexpected fixture mode"
    }
    await_removed(system, close)
    process.receive(system.closed, 1000)
    |> should.equal(
      Ok(socket.EncodingFailed(codec.MetadataTooLong("topic", 256))),
    )
    beryl.stop(system.sockets) |> should.equal(Ok(Nil))
  })
}

pub fn failure_after_async_presence_reclaims_tracked_presence_test() -> Nil {
  let handle = start_presence()
  let system = start(PushFailure, handle)
  let close = process.new_subject()
  let frames = connect(system, "failed", None, close)
  joined(system, frames)
  helper.push(system.sockets, "failed", "room:a", "presence", "event")
  let _diff = receive_frame(frames)
  await_removed(system, close)
  presence.list(handle, "room:a") |> should.equal(Ok([]))
  process.receive(system.calls, 1000) |> should.equal(Ok("push:presence_diff"))
  process.receive(system.calls, 1000) |> should.equal(Ok("push:fail"))
  process.receive(system.calls, 10) |> should.equal(Error(Nil))
  beryl.stop(system.sockets) |> should.equal(Ok(Nil))
}

pub fn binary_metadata_limit_counts_utf8_bytes_test() -> Nil {
  let system = start(BinaryReply, start_presence())
  let close = process.new_subject()
  let frames = connect(system, "failed", None, close)
  let accepted = "room:" <> string.repeat("\u{e9}", 125)
  helper.join(system.sockets, "failed", accepted, "join", "join")
  let assert codec.BinaryFrame(_) = receive_frame(frames)
  helper.join(system.sockets, "failed", accepted <> "x", "join2", "join2")
  await_removed(system, close)
  process.receive(system.closed, 1000)
  |> should.equal(
    Ok(socket.EncodingFailed(codec.MetadataTooLong("topic", 256))),
  )
  beryl.stop(system.sockets) |> should.equal(Ok(Nil))
}

pub fn inline_broadcast_failure_does_not_abort_healthy_recipients_test() -> Nil {
  let system = start(PushFailure, start_presence())
  let close = process.new_subject()
  let frames = connect(system, "failed", None, close)
  joined(system, frames)
  let peer_close = process.new_subject()
  let peer = connect(system, "healthy", Some(wire.phoenix_codec()), peer_close)
  helper.join(system.sockets, "healthy", "room:a", "peer", "peer")
  let _ = receive_frame(peer)
  helper.push(system.sockets, "failed", "room:a", "broadcast", "event")
  receive_frame(peer) |> should.equal(wire.push("room:a", "fail", json.null()))
  process.receive(close, 2000) |> should.equal(Ok(Nil))
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(system.sockets)
      snapshot.connected_sockets(current) == 1
    },
    1000,
    5,
  )
  process.receive(peer, 10) |> should.equal(Error(Nil))
  process.receive(frames, 10) |> should.equal(Error(Nil))
  process.receive(peer_close, 10) |> should.equal(Error(Nil))
  beryl.stop(system.sockets) |> should.equal(Ok(Nil))
}

pub fn routed_broadcast_failure_closes_only_its_recipient_test() -> Nil {
  let system = start(PushFailure, start_presence())
  let close = process.new_subject()
  let frames = connect(system, "failed", None, close)
  joined(system, frames)
  let peer_close = process.new_subject()
  let peer = connect(system, "healthy", Some(wire.phoenix_codec()), peer_close)
  helper.join(system.sockets, "healthy", "room:a", "peer", "peer")
  let _ = receive_frame(peer)
  beryl.broadcast(system.sockets, "room:a", "fail", json.null())
  |> should.equal(Ok(Nil))
  receive_frame(peer) |> should.equal(wire.push("room:a", "fail", json.null()))
  process.receive(close, 2000) |> should.equal(Ok(Nil))
  process.receive(system.closed, 1000)
  |> should.equal(Ok(socket.EncodingFailed(rejected())))
  process.receive(frames, 10) |> should.equal(Error(Nil))
  process.receive(peer_close, 10) |> should.equal(Error(Nil))
  beryl.stop(system.sockets) |> should.equal(Ok(Nil))
}

pub fn worker_reply_failure_finishes_termination_and_discards_suffix_test() -> Nil {
  let calls = process.new_subject()
  let reports = process.new_subject()
  let sockets =
    channel_dispatch_helper.start(
      beryl.config(fallible_codec(ReplyFailure, calls)),
      [
        channel.handler("room:*", fn(_context) {
          process.send(reports, #("join", process.self()))
          channel.accept(Nil)
          |> channel.on_message(fn(state, message) {
            channel.next(state, [
              channel.reply_ok(message.reply, json.null()),
              channel.push("suffix", json.null()),
            ])
          })
          |> channel.on_terminate(fn(_state, reason) {
            reason |> should.equal(socket.EncodingFailed(rejected()))
            process.send(reports, #("terminated", process.self()))
            []
          })
        }),
      ],
    )
  let frames = channel_dispatch_helper.connect(sockets, "worker")
  channel_dispatch_helper.join(sockets, "worker", "room:a", "join", "join")
  let _ = helper.recv(frames)
  let assert Ok(#("join", worker)) = process.receive(reports, 1000)
  let monitor = process.monitor(worker)
  channel_dispatch_helper.push(sockets, "worker", "room:a", "reply", "fail")
  process.receive(reports, 2000) |> should.equal(Ok(#("terminated", worker)))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
  helper.recv_none(frames)
  process.receive(calls, 1000) |> should.equal(Ok("reply"))
  process.receive(calls, 1000) |> should.equal(Ok("reply"))
  process.receive(calls, 10) |> should.equal(Error(Nil))
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn worker_join_reply_failure_releases_initial_report_test() -> Nil {
  let calls = process.new_subject()
  let workers = process.new_subject()
  let terminated = process.new_subject()
  let sockets =
    channel_dispatch_helper.start(
      beryl.config(fallible_codec(ReplyFailure, calls)),
      [
        channel.handler("room:*", fn(_context) {
          process.send(workers, process.self())
          channel.accept(Nil)
          |> channel.with_actions([channel.push("suffix", json.null())])
          |> channel.on_terminate(fn(_state, reason) {
            process.send(terminated, reason)
            []
          })
        }),
      ],
    )
  let frames = channel_dispatch_helper.connect(sockets, "worker")
  channel_dispatch_helper.join(sockets, "worker", "room:a", "join", "fail")
  let assert Ok(worker) = process.receive(workers, 1000)
  let monitor = process.monitor(worker)
  process.receive(terminated, 2000)
  |> should.equal(Ok(socket.EncodingFailed(rejected())))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
  helper.recv_none(frames)
  process.receive(calls, 1000) |> should.equal(Ok("reply"))
  process.receive(calls, 10) |> should.equal(Error(Nil))
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn failure_during_topic_close_preserves_both_presence_cleanups_test() -> Nil {
  let handle = start_presence()
  let calls = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(sockets) =
    helper.start_app(
      beryl.config(fallible_codec(PushFailure, calls))
        |> beryl.with_presence_handle(handle),
      init: helper.accepting_init,
      update: fn(model, input) {
        case input {
          socket.Join(topic, _, reference) ->
            socket.Next(model, [
              socket.AcceptJoin(reference, None),
              socket.PresenceTrack(topic, "tracked", json.null()),
            ])
          socket.Message(topic, "kick", _, _) ->
            socket.Next(model, [socket.KickTopic(topic)])
          socket.Closed("room:a", reason) -> {
            process.send(closed, reason)
            socket.Next(model, [
              socket.Push("room:b", "fail", json.null()),
            ])
          }
          socket.Closed(_, reason) -> {
            process.send(closed, reason)
            socket.Next(model, [])
          }
          socket.Message(..) | socket.Binary(..) | socket.Info(..) ->
            socket.Next(model, [])
        }
      },
    )
  let transport_closed = process.new_subject()
  let frames =
    helper.connect_with_close(sockets, "nested", fn() {
      process.send(transport_closed, Nil)
    })
  list.each(["room:a", "room:b"], fn(topic) {
    helper.join(sockets, "nested", topic, topic, topic)
    let _reply = helper.recv(frames)
    let _diff = helper.recv(frames)
  })
  helper.push(sockets, "nested", "room:a", "kick", "event")
  process.receive(closed, 1000) |> should.equal(Ok(socket.Shutdown))
  process.receive(closed, 1000)
  |> should.equal(Ok(socket.EncodingFailed(rejected())))
  process.receive(transport_closed, 2000) |> should.equal(Ok(Nil))
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.connected_sockets(current) == 0
    },
    1000,
    5,
  )
  presence.list(handle, "room:a") |> should.equal(Ok([]))
  presence.list(handle, "room:b") |> should.equal(Ok([]))
  process.receive(transport_closed, 10) |> should.equal(Error(Nil))
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn draining_worker_failure_preserves_its_wait_and_presence_cleanup_test() -> Nil {
  let handle = start_presence()
  let calls = process.new_subject()
  let entered = process.new_subject()
  let terminated = process.new_subject()
  let sockets =
    channel_dispatch_helper.start(
      beryl.config(fallible_codec(PushFailure, calls))
        |> beryl.with_presence_handle(handle),
      [
        channel.handler("room:*", fn(context) {
          channel.accept(Nil)
          |> channel.with_actions([
            channel.presence_track("tracked", json.null()),
          ])
          |> channel.on_message(fn(state, _message) {
            let release = process.new_subject()
            process.send(entered, #(process.self(), release))
            let assert Ok(Nil) = process.receive(release, 2000)
            channel.next(state, [
              channel.push("fail", json.null()),
              channel.push("suffix", json.null()),
            ])
          })
          |> channel.on_terminate(fn(_state, reason) {
            process.send(terminated, #(context.topic, reason))
            []
          })
        }),
      ],
    )
  let closed = process.new_subject()
  let frames =
    helper.connect_with_close(sockets, "draining", fn() {
      process.send(closed, Nil)
    })
  list.each(["room:a", "room:b"], fn(topic) {
    helper.join(sockets, "draining", topic, topic, topic)
    let _reply = helper.recv(frames)
    let _diff = helper.recv(frames)
  })
  helper.push(sockets, "draining", "room:a", "blocked", "event")
  let assert Ok(#(worker, release)) = process.receive(entered, 1000)
  let monitor = process.monitor(worker)
  helper.route(
    sockets,
    "draining",
    "[\"room:a\",\"leave\",\"room:a\",\"phx_leave\",{}]",
  )
  helper.recv(frames) |> string.contains("\"leave\"") |> should.be_true
  process.send(release, Nil)
  process.receive(closed, 2000) |> should.equal(Ok(Nil))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  process.receive(terminated, 1000)
  |> should.equal(Ok(#("room:a", socket.Normal)))
  process.receive(terminated, 1000)
  |> should.equal(Ok(#("room:b", socket.EncodingFailed(rejected()))))
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.connected_sockets(current) == 0
    },
    1000,
    5,
  )
  presence.list(handle, "room:a") |> should.equal(Ok([]))
  presence.list(handle, "room:b") |> should.equal(Ok([]))
  helper.recv_none(frames)
  process.receive(closed, 10) |> should.equal(Error(Nil))
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
