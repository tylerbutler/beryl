import app_test_helper
import beryl
import beryl/channel
import beryl/overload
import beryl/presence
import beryl/pubsub
import beryl/snapshot
import beryl/socket.{
  AcceptJoin, Binary, Broadcast, BroadcastFrom, Closed, Info, Join, Message,
  Next, Push, RejectJoin, ReplyError, ReplyOk,
}
import beryl/telemetry
import beryl/transport
import beryl/wire
import beryl/wire/codec
import channel_dispatch_helper
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import test_helper
import unitest

/// Opaque handle to the attached :telemetry capture handler, produced and
/// consumed only by the test FFI — never inspected from Gleam.
type TelemetryHandle

@external(erlang, "beryl_runtime_telemetry_test_ffi", "attach")
fn attach() -> TelemetryHandle

@external(erlang, "beryl_runtime_telemetry_test_ffi", "detach")
fn detach(handler_id: TelemetryHandle) -> Nil

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_connected")
fn expect_connected(handler_id: TelemetryHandle) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_join")
fn expect_join(handler_id: TelemetryHandle, outcome: String) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_message")
fn expect_message(
  handler_id: TelemetryHandle,
  kind: String,
  outcome: String,
  callback_result: String,
) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_disconnect")
fn expect_disconnect(
  handler_id: TelemetryHandle,
  reason: String,
  joined_channels: Int,
) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_disconnect_after")
fn expect_disconnect_after(
  handler_id: TelemetryHandle,
  reason: String,
  joined_channels: Int,
  minimum_duration: Int,
) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_broadcast")
fn expect_broadcast(
  handler_id: TelemetryHandle,
  origin: String,
  recipients: Int,
) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_none")
fn expect_none(handler_id: TelemetryHandle) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "with_capture")
fn with_capture(action: fn(TelemetryHandle) -> a) -> a

@external(erlang, "beryl_runtime_telemetry_test_ffi", "with_race_runtime")
fn with_race_runtime(
  supervisor: process.Pid,
  notify_closed: fn() -> Nil,
  stop: fn() -> Nil,
  drain: fn() -> Nil,
  action: fn(fn() -> Nil, fn() -> Nil) -> a,
) -> a

@external(erlang, "beryl_runtime_telemetry_test_ffi", "with_actor_monitor")
fn with_actor_monitor(actor: process.Pid, action: fn(process.Monitor) -> a) -> a

@external(erlang, "beryl_test_process_ffi", "with_suspended")
fn with_suspended(pid: process.Pid, action: fn() -> a) -> a

@external(erlang, "beryl_runtime_telemetry_test_ffi", "catch_injected_assertion")
fn catch_injected_assertion(action: fn() -> Nil) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "cleanup_baseline")
fn cleanup_baseline(action: fn() -> Nil) -> Bool

type RaceStage {
  RuntimeStarted
  Admitted
  Connected
  Suspended
  Released
  ActorExited
  Verified
}

type AppMessage {
  Tick
}

pub fn presence_callbacks_use_the_presence_telemetry_kind_test() -> Nil {
  use <- unitest.tag("serial")
  let capture = attach()
  let assert Ok(presence) = presence.start(presence.default_config("telemetry"))
  let sockets =
    channel_dispatch_helper.start(
      telemetry_config() |> beryl.with_presence_handle(presence),
      handlers: [
        channel.handler("room:*", fn(_) {
          channel.accept(Nil)
          |> channel.on_presence(fn(state, _) { channel.stay(state) })
        }),
      ],
    )
  let frames = channel_dispatch_helper.connect(sockets, "s1")
  channel_dispatch_helper.join(sockets, "s1", "room:a", "join", "1")
  let _reply = channel_dispatch_helper.recv(frames)
  expect_connected(capture) |> should.be_true
  expect_join(capture, "accepted") |> should.be_true
  expect_message(capture, "presence", "handled", "no_reply") |> should.be_true
  expect_none(capture) |> should.be_true
  detach(capture)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  let _close = channel_dispatch_helper.recv(frames)
  Nil
}

fn telemetry_config() -> beryl.Config {
  beryl.config(wire.phoenix_codec())
  |> beryl.with_telemetry
}

fn update(model: Nil, input: socket.Input(AppMessage)) -> socket.Next(Nil) {
  case input {
    Join("room:reject", _, ref) ->
      Next(model, [RejectJoin(ref, json.object([]))])
    Join("room:crash", _, _) -> panic as "expected join failure"
    Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
    Message(_, "reply", _, Some(ref)) ->
      Next(model, [ReplyOk(ref, json.object([]))])
    Message(_, "reply_error", _, Some(ref)) ->
      Next(model, [ReplyError(ref, json.object([]))])
    Message(topic, "push", _, _) ->
      Next(model, [Push(topic, "pushed", json.object([]))])
    Message(topic, "cast", _, _) ->
      Next(model, [
        Broadcast(topic, "notice", json.object([])),
        Push(topic, "after", json.object([])),
      ])
    Message(topic, "cast_others", _, _) ->
      Next(model, [BroadcastFrom(topic, "notice", json.object([]))])
    Message(_, "cast_unjoined", _, _) ->
      Next(model, [Broadcast("room:other", "notice", json.object([]))])
    Message(topic, "cast_oversized", _, _) ->
      Next(model, [
        Broadcast(topic, "notice", json.string(string.repeat("x", 4096))),
      ])
    Message(_, "crash", _, _) -> panic as "expected message failure"
    Message(_, "stop", _, _) -> socket.Stop(socket.Errored("application stop"))
    Message(_, _, _, _) | Binary(_, _) | Info(_) -> Next(model, [])
    Closed(_, _) -> Next(model, [])
  }
}

fn start(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config,
      init: fn(_info: socket.ConnectInfo(AppMessage)) { #(Nil, []) },
      update: update,
    )
  sockets
}

fn route_heartbeat(sockets: beryl.Sockets, socket_id: String) -> Nil {
  app_test_helper.route(
    sockets,
    socket_id,
    "[null,\"heartbeat-ref\",\"phoenix\",\"heartbeat\",{}]",
  )
}

pub fn lifecycle_and_callback_results_emit_once_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let sockets = start(telemetry_config())
  let frames = app_test_helper.connect(sockets, "socket-1")
  expect_connected(handler) |> should.be_true

  app_test_helper.join(sockets, "socket-1", "room:lobby", "join-ref", "1")
  let _join_reply = app_test_helper.recv(frames)
  expect_join(handler, "accepted") |> should.be_true

  app_test_helper.push(sockets, "socket-1", "room:lobby", "noop", "2")
  expect_message(handler, "text", "handled", "no_reply") |> should.be_true

  app_test_helper.push(sockets, "socket-1", "room:lobby", "reply", "3")
  let _reply = app_test_helper.recv(frames)
  expect_message(handler, "text", "handled", "reply") |> should.be_true

  app_test_helper.push(sockets, "socket-1", "room:lobby", "reply_error", "4")
  let _error_reply = app_test_helper.recv(frames)
  expect_message(handler, "text", "handled", "reply_error") |> should.be_true

  app_test_helper.push(sockets, "socket-1", "room:lobby", "push", "5")
  let _push = app_test_helper.recv(frames)
  expect_message(handler, "text", "handled", "push") |> should.be_true

  route_heartbeat(sockets, "socket-1")
  let _heartbeat_reply = app_test_helper.recv(frames)
  expect_message(handler, "heartbeat", "handled", "not_applicable")
  |> should.be_true

  transport.socket_disconnected(sockets, "socket-1")
  expect_disconnect(handler, "normal", 1) |> should.be_true
  expect_none(handler) |> should.be_true
  detach(handler)
  let assert Ok(Nil) = beryl.stop(sockets)
  Nil
}

pub fn join_terminal_outcomes_are_reported_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let sockets = start(telemetry_config())
  let frames = app_test_helper.connect(sockets, "join-outcomes")
  expect_connected(handler) |> should.be_true

  app_test_helper.join(sockets, "join-outcomes", "room:reject", "jr-1", "1")
  let _rejected = app_test_helper.recv(frames)
  expect_join(handler, "handler_rejected") |> should.be_true

  app_test_helper.join(sockets, "join-outcomes", "beryl:reserved", "jr-2", "2")
  let _invalid = app_test_helper.recv(frames)
  expect_join(handler, "invalid_topic") |> should.be_true

  app_test_helper.join(sockets, "join-outcomes", "room:crash", "jr-3", "3")
  let _crashed = app_test_helper.recv(frames)
  expect_join(handler, "callback_error") |> should.be_true

  let limited =
    start(
      telemetry_config()
      |> beryl.with_join_rate(per_second: 1, burst: 1),
    )
  let limited_frames = app_test_helper.connect(limited, "limited")
  expect_connected(handler) |> should.be_true
  app_test_helper.join(limited, "limited", "room:first", "jr-1", "1")
  let _accepted = app_test_helper.recv(limited_frames)
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.join(limited, "limited", "room:second", "jr-2", "2")
  let _rate_limited = app_test_helper.recv(limited_frames)
  expect_join(handler, "rate_limited") |> should.be_true

  expect_none(handler) |> should.be_true
  detach(handler)
}

pub fn message_rejection_rate_limit_and_crash_are_terminal_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let limited =
    start(
      telemetry_config()
      |> beryl.with_message_rate(per_second: 1, burst: 1),
    )
  let frames = app_test_helper.connect(limited, "limited")
  expect_connected(handler) |> should.be_true

  app_test_helper.push(limited, "limited", "room:lobby", "noop", "1")
  let _unmatched = app_test_helper.recv(frames)
  expect_message(handler, "text", "unjoined", "not_applicable")
  |> should.be_true
  app_test_helper.push(limited, "limited", "room:lobby", "noop", "2")
  expect_message(handler, "text", "rate_limited", "not_applicable")
  |> should.be_true

  let crashed = start(telemetry_config())
  let crashed_frames = app_test_helper.connect(crashed, "crashed")
  expect_connected(handler) |> should.be_true
  app_test_helper.join(crashed, "crashed", "room:lobby", "jr-1", "1")
  let _joined = app_test_helper.recv(crashed_frames)
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(crashed, "crashed", "room:lobby", "crash", "2")
  expect_message(handler, "text", "callback_error", "failed")
  |> should.be_true

  expect_none(handler) |> should.be_true
  detach(handler)
}

pub fn decoded_binary_route_preserves_message_kind_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let sockets = start(telemetry_config())
  let frames = app_test_helper.connect(sockets, "decoded-binary")
  expect_connected(handler) |> should.be_true

  app_test_helper.join(sockets, "decoded-binary", "room:lobby", "join-ref", "1")
  let _joined = app_test_helper.recv(frames)
  expect_join(handler, "accepted") |> should.be_true

  let text_event = "[\"join-ref\",\"text-ref\",\"room:lobby\",\"noop\",{}]"
  let assert Ok(text_message) =
    codec.decode_text(transport.active_codec(sockets))(text_event)
  let assert Ok(_) =
    transport.route_decoded(sockets, "decoded-binary", text_message)
  expect_message(handler, "text", "handled", "no_reply") |> should.be_true

  let binary_event = <<
    0,
    8,
    10,
    10,
    4,
    "join-ref":utf8,
    "binary-ref":utf8,
    "room:lobby":utf8,
    "noop":utf8,
    1,
  >>
  let assert Some(decode_binary) =
    codec.decode_binary(transport.active_codec(sockets))
  let assert Ok(binary_message) = decode_binary(binary_event)
  let assert Ok(_) =
    transport.route_decoded_binary(sockets, "decoded-binary", binary_message)
  expect_message(handler, "binary", "handled", "no_reply") |> should.be_true

  expect_none(handler) |> should.be_true
  detach(handler)
  let assert Ok(Nil) = beryl.stop(sockets)
  Nil
}

pub fn invalid_decoded_events_emit_one_terminal_outcome_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let inputs = process.new_subject()
  let sockets = app_test_helper.start_observed(telemetry_config(), inputs)
  let frames = app_test_helper.connect(sockets, "invalid")
  expect_connected(handler) |> should.be_true
  app_test_helper.join(sockets, "invalid", "room:lobby", "join", "1")
  let _joined = app_test_helper.recv(frames)
  let assert Join(..) = app_test_helper.next_event(inputs)
  expect_join(handler, "accepted") |> should.be_true

  let long_topic = string.repeat("x", 257)
  route_invalid(sockets, "invalid", long_topic, "noop", False)
  route_invalid(sockets, "invalid", "room:lobby", "phx_bad", False)
  route_invalid(sockets, "invalid", long_topic, "phx_bad", True)
  route_invalid(sockets, "invalid", "room:lobby", "phx_bad", True)
  app_test_helper.push(sockets, "invalid", "room:lobby", "barrier", "2")
  expect_message(handler, "text", "handled", "no_reply") |> should.be_true
  let assert Message("room:lobby", "barrier", _, _) =
    app_test_helper.next_event(inputs)
  process.receive(inputs, 0) |> should.be_error
  expect_message(handler, "text", "invalid", "not_applicable")
  |> should.be_true
  expect_message(handler, "text", "invalid", "not_applicable")
  |> should.be_true
  expect_message(handler, "binary", "invalid", "not_applicable")
  |> should.be_true
  expect_message(handler, "binary", "invalid", "not_applicable")
  |> should.be_true
  expect_none(handler) |> should.be_true
  detach(handler)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

fn route_invalid(
  sockets: beryl.Sockets,
  socket_id: String,
  topic: String,
  event: String,
  binary: Bool,
) -> Nil {
  let raw =
    json.array(
      [
        json.null(),
        json.null(),
        json.string(topic),
        json.string(event),
        json.object([]),
      ],
      fn(value) { value },
    )
    |> json.to_string
  let assert Ok(message) =
    codec.decode_text(transport.active_codec(sockets))(raw)
  case binary {
    True -> transport.route_decoded_binary(sockets, socket_id, message)
    False -> transport.route_decoded(sockets, socket_id, message)
  }
  |> should.be_ok
}

pub fn invalid_event_rate_limit_precedes_validation_and_disabled_is_silent_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let limited =
    start(
      telemetry_config() |> beryl.with_message_rate(per_second: 1, burst: 1),
    )
  let frames = app_test_helper.connect(limited, "limited-invalid")
  expect_connected(handler) |> should.be_true
  app_test_helper.join(limited, "limited-invalid", "room:lobby", "join", "1")
  let _joined = app_test_helper.recv(frames)
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(limited, "limited-invalid", "room:lobby", "noop", "2")
  expect_message(handler, "text", "handled", "no_reply") |> should.be_true
  route_invalid(limited, "limited-invalid", "room:lobby", "phx_bad", True)
  expect_message(handler, "binary", "rate_limited", "not_applicable")
  |> should.be_true
  // A join reply is an ordering barrier that does not use the message bucket.
  app_test_helper.join(
    limited,
    "limited-invalid",
    "room:barrier",
    "join-2",
    "3",
  )
  let _barrier = app_test_helper.recv(frames)
  expect_join(handler, "accepted") |> should.be_true
  expect_none(handler) |> should.be_true
  detach(handler)
  beryl.stop(limited) |> should.equal(Ok(Nil))

  let handler = attach()
  let disabled = start(beryl.config(wire.phoenix_codec()))
  let disabled_frames = app_test_helper.connect(disabled, "disabled-invalid")
  route_invalid(disabled, "disabled-invalid", "room:lobby", "phx_bad", False)
  route_invalid(
    disabled,
    "disabled-invalid",
    string.repeat("x", 257),
    "phx_bad",
    True,
  )
  route_heartbeat(disabled, "disabled-invalid")
  let _barrier = app_test_helper.recv(disabled_frames)
  expect_none(handler) |> should.be_true
  detach(handler)
  beryl.stop(disabled) |> should.equal(Ok(Nil))
}

fn raw_binary_codec() -> codec.Codec {
  codec.new(
    decode_text: wire.decode_message,
    encode_reply: wire.reply_json,
    encode_push: wire.push,
    encode_heartbeat_reply: wire.heartbeat_reply,
  )
  |> codec.with_close_encoder(wire.channel_close)
  |> codec.with_error_encoder(wire.channel_error)
}

pub fn binary_info_and_broadcast_counts_are_reported_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let pubsub_instance = pubsub.start(pubsub.default_config())
  let senders = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(raw_binary_codec())
        |> beryl.with_pubsub(pubsub_instance)
        |> beryl.with_telemetry,
      init: fn(info: socket.ConnectInfo(AppMessage)) {
        process.send(senders, info.self)
        #(Nil, [])
      },
      update: update,
    )
  let frames = app_test_helper.connect(sockets, "ok")
  let assert Ok(sender) = process.receive(senders, 500)
  expect_connected(handler) |> should.be_true
  app_test_helper.join(sockets, "ok", "room:lobby", "jr-1", "1")
  let _joined = app_test_helper.recv(frames)
  expect_join(handler, "accepted") |> should.be_true

  let assert Ok(_) = transport.route_binary(sockets, "ok", <<1, 2, 3>>)
  expect_message(handler, "binary", "handled", "no_reply") |> should.be_true
  let assert Ok(_) = socket.notify(sender, Tick)
  expect_message(handler, "info", "handled", "no_reply") |> should.be_true

  let assert Ok(_) =
    beryl.broadcast(sockets, "room:lobby", "event", json.object([]))
  let _local = app_test_helper.recv(frames)
  expect_broadcast(handler, "local", 1) |> should.be_true

  pubsub.broadcast(pubsub_instance, "room:lobby", "remote", json.object([]))
  let _remote = app_test_helper.recv(frames)
  expect_broadcast(handler, "remote", 1) |> should.be_true

  expect_none(handler) |> should.be_true
  detach(handler)
}

pub fn socket_broadcast_counts_actual_inline_recipients_once_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let sockets = start(telemetry_config())
  let sender = app_test_helper.connect(sockets, "sender")
  expect_connected(handler) |> should.be_true
  app_test_helper.join_ok(sockets, sender, "sender", "room:lobby", "j", "1")
  expect_join(handler, "accepted") |> should.be_true

  app_test_helper.push(sockets, "sender", "room:lobby", "cast", "2")
  app_test_helper.recv(sender)
  |> codec.TextFrame
  |> should.equal(wire.push("room:lobby", "notice", json.object([])))
  app_test_helper.recv(sender)
  |> codec.TextFrame
  |> should.equal(wire.push("room:lobby", "after", json.object([])))
  expect_message(handler, "text", "handled", "push") |> should.be_true
  expect_broadcast(handler, "local", 1) |> should.be_true

  let observer = app_test_helper.connect(sockets, "observer")
  expect_connected(handler) |> should.be_true
  app_test_helper.join_ok(
    sockets,
    observer,
    "observer",
    "room:lobby",
    "j2",
    "1",
  )
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(sockets, "sender", "room:lobby", "cast", "3")
  let _inline = app_test_helper.recv(sender)
  let _after = app_test_helper.recv(sender)
  let _routed = app_test_helper.recv(observer)
  expect_message(handler, "text", "handled", "push") |> should.be_true
  expect_broadcast(handler, "local", 2) |> should.be_true

  app_test_helper.push(sockets, "sender", "room:lobby", "cast_others", "4")
  let _routed = app_test_helper.recv(observer)
  expect_message(handler, "text", "handled", "push") |> should.be_true
  expect_broadcast(handler, "local", 1) |> should.be_true
  route_heartbeat(sockets, "sender")
  app_test_helper.recv(sender)
  |> string.contains("heartbeat-ref")
  |> should.be_true
  expect_message(handler, "heartbeat", "handled", "not_applicable")
  |> should.be_true

  app_test_helper.join_ok(
    sockets,
    observer,
    "observer",
    "room:other",
    "j3",
    "2",
  )
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(sockets, "sender", "room:lobby", "cast_unjoined", "5")
  app_test_helper.recv(observer)
  |> codec.TextFrame
  |> should.equal(wire.push("room:other", "notice", json.object([])))
  expect_message(handler, "text", "handled", "push") |> should.be_true
  expect_broadcast(handler, "local", 1) |> should.be_true
  route_heartbeat(sockets, "sender")
  app_test_helper.recv(sender)
  |> string.contains("heartbeat-ref")
  |> should.be_true
  expect_message(handler, "heartbeat", "handled", "not_applicable")
  |> should.be_true

  beryl.broadcast(sockets, "room:lobby", "public", json.object([]))
  |> should.be_ok
  let _sender = app_test_helper.recv(sender)
  let _observer = app_test_helper.recv(observer)
  expect_broadcast(handler, "local", 2) |> should.be_true
  expect_none(handler) |> should.be_true
  detach(handler)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn socket_broadcast_pubsub_counts_each_runtime_fanout_once_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let instance =
    pubsub.start(pubsub.config_with_scope("telemetry-inline-count"))
  let config = telemetry_config() |> beryl.with_pubsub(instance)
  let local = start(config)
  let remote = start(config)
  let sender = app_test_helper.connect(local, "sender")
  let observer = app_test_helper.connect(remote, "observer")
  expect_connected(handler) |> should.be_true
  expect_connected(handler) |> should.be_true
  app_test_helper.join_ok(local, sender, "sender", "room:lobby", "j1", "1")
  app_test_helper.join_ok(remote, observer, "observer", "room:lobby", "j2", "1")
  expect_join(handler, "accepted") |> should.be_true
  expect_join(handler, "accepted") |> should.be_true
  test_helper.wait_until(
    fn() { pubsub.subscriber_count(instance, "room:lobby") == 2 },
    1000,
    5,
  )
  app_test_helper.push(local, "sender", "room:lobby", "cast", "2")
  let _inline = app_test_helper.recv(sender)
  let _after = app_test_helper.recv(sender)
  let _remote = app_test_helper.recv(observer)
  expect_message(handler, "text", "handled", "push") |> should.be_true
  expect_broadcast(handler, "local", 1) |> should.be_true
  expect_broadcast(handler, "remote", 1) |> should.be_true

  beryl.broadcast(local, "room:lobby", "public", json.object([]))
  |> should.be_ok
  let _local = app_test_helper.recv(sender)
  let _remote = app_test_helper.recv(observer)
  expect_broadcast(handler, "local", 1) |> should.be_true
  expect_broadcast(handler, "remote", 1) |> should.be_true
  expect_none(handler) |> should.be_true
  detach(handler)
  beryl.stop(local) |> should.equal(Ok(Nil))
  beryl.stop(remote) |> should.equal(Ok(Nil))
}

pub fn rejected_router_broadcast_sends_no_inline_copy_or_success_event_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let assert Ok(limits) = overload.limits(32, 1024)
  let sockets =
    start(
      telemetry_config()
      |> beryl.with_router_queue_limits(limits),
    )
  let frames = app_test_helper.connect(sockets, "rejected")
  expect_connected(handler) |> should.be_true
  app_test_helper.join_ok(sockets, frames, "rejected", "room:lobby", "j", "1")
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(sockets, "rejected", "room:lobby", "cast_oversized", "2")
  expect_message(handler, "text", "handled", "push") |> should.be_true
  expect_disconnect(handler, "normal", 1) |> should.be_true
  app_test_helper.recv(frames)
  |> should.equal("[\"j\",\"j\",\"room:lobby\",\"phx_close\",{}]")
  app_test_helper.recv_none(frames)
  expect_none(handler) |> should.be_true
  detach(handler)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn raising_sender_write_does_not_prevent_broadcast_fanout_test() -> Nil {
  use <- unitest.tag("serial")
  assert_faulty_sender_fanout("telemetry-write-fault", None, fn(frame) {
    case string.contains(frame, "\"notice\"") {
      True -> panic as "expected sender write failure"
      False -> Ok(Nil)
    }
  })
}

pub fn raising_sender_codec_does_not_prevent_broadcast_fanout_test() -> Nil {
  use <- unitest.tag("serial")
  let faulty_codec =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: wire.reply_json,
      encode_push: fn(_, _, _) { panic as "expected sender codec failure" },
      encode_heartbeat_reply: wire.heartbeat_reply,
    )
  assert_faulty_sender_fanout(
    "telemetry-codec-fault",
    Some(faulty_codec),
    fn(_) { Ok(Nil) },
  )
}

fn assert_faulty_sender_fanout(
  scope: String,
  sender_codec: option.Option(codec.Codec),
  send: fn(String) -> Result(Nil, Nil),
) -> Nil {
  let handler = attach()
  let instance = pubsub.start(pubsub.config_with_scope(scope))
  let config = telemetry_config() |> beryl.with_pubsub(instance)
  let local = start(config)
  let remote = start(config)
  let sender = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(local)
  transport.admit_socket(
    sockets: local,
    owner: owner,
    socket_id: "faulty-sender",
    send: fn(frame) {
      let result = send(frame)
      process.send(sender, frame)
      result
    },
    send_binary: fn(_) { Ok(Nil) },
    codec: sender_codec,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  let local_observer = app_test_helper.connect(local, "local-observer")
  let remote_observer = app_test_helper.connect(remote, "remote-observer")
  expect_connected(handler) |> should.be_true
  expect_connected(handler) |> should.be_true
  expect_connected(handler) |> should.be_true
  app_test_helper.join_ok(
    local,
    sender,
    "faulty-sender",
    "room:lobby",
    "j1",
    "1",
  )
  app_test_helper.join_ok(
    local,
    local_observer,
    "local-observer",
    "room:lobby",
    "j2",
    "1",
  )
  app_test_helper.join_ok(
    remote,
    remote_observer,
    "remote-observer",
    "room:lobby",
    "j3",
    "1",
  )
  expect_join(handler, "accepted") |> should.be_true
  expect_join(handler, "accepted") |> should.be_true
  expect_join(handler, "accepted") |> should.be_true
  test_helper.wait_until(
    fn() { pubsub.subscriber_count(instance, "room:lobby") == 2 },
    1000,
    5,
  )

  app_test_helper.push(local, "faulty-sender", "room:lobby", "cast", "2")
  app_test_helper.recv(local_observer)
  |> codec.TextFrame
  |> should.equal(wire.push("room:lobby", "notice", json.object([])))
  app_test_helper.recv(remote_observer)
  |> codec.TextFrame
  |> should.equal(wire.push("room:lobby", "notice", json.object([])))
  expect_broadcast(handler, "local", 2) |> should.be_true
  expect_broadcast(handler, "remote", 1) |> should.be_true

  route_heartbeat(local, "local-observer")
  app_test_helper.recv(local_observer)
  |> string.contains("heartbeat-ref")
  |> should.be_true
  route_heartbeat(remote, "remote-observer")
  app_test_helper.recv(remote_observer)
  |> string.contains("heartbeat-ref")
  |> should.be_true
  expect_message(handler, "heartbeat", "handled", "not_applicable")
  |> should.be_true
  expect_message(handler, "heartbeat", "handled", "not_applicable")
  |> should.be_true
  expect_disconnect(handler, "socket_process_down", 1) |> should.be_true
  expect_none(handler) |> should.be_true
  detach(handler)
  beryl.stop(local) |> should.equal(Ok(Nil))
  beryl.stop(remote) |> should.equal(Ok(Nil))
}

pub fn channel_rate_allowance_survives_duplicate_join_and_leave_rejoin_test() -> Nil {
  use <- unitest.tag("serial")
  assert_rejoin_preserves_rate(
    telemetry_config() |> beryl.with_channel_rate(per_second: 1, burst: 1),
  )
}

pub fn topic_rate_allowance_survives_duplicate_join_and_leave_rejoin_test() -> Nil {
  use <- unitest.tag("serial")
  assert_rejoin_preserves_rate(
    telemetry_config()
    |> beryl.with_channel_rate(per_second: 1000, burst: 1000)
    |> beryl.with_topic_rate("room:*", per_second: 1, burst: 1),
  )
}

fn assert_rejoin_preserves_rate(config: beryl.Config) -> Nil {
  let handler = attach()
  let inputs = process.new_subject()
  let sockets = app_test_helper.start_observed(config, inputs)
  let frames = app_test_helper.connect(sockets, "retained")
  expect_connected(handler) |> should.be_true
  app_test_helper.join_ok(sockets, frames, "retained", "room:lobby", "j1", "1")
  let assert Join("room:lobby", _, _) = app_test_helper.next_event(inputs)
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(sockets, "retained", "room:lobby", "first", "2")
  let assert Message("room:lobby", "first", _, _) =
    app_test_helper.next_event(inputs)
  expect_message(handler, "text", "handled", "no_reply") |> should.be_true
  app_test_helper.push(sockets, "retained", "room:lobby", "exhausted", "3")
  expect_message(handler, "text", "rate_limited", "not_applicable")
  |> should.be_true

  app_test_helper.join(sockets, "retained", "room:lobby", "j2", "4")
  app_test_helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  let assert Closed("room:lobby", socket.Normal) =
    app_test_helper.next_event(inputs)
  let assert Join("room:lobby", _, _) = app_test_helper.next_event(inputs)
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(
    sockets,
    "retained",
    "room:lobby",
    "after_duplicate",
    "5",
  )
  expect_message(handler, "text", "rate_limited", "not_applicable")
  |> should.be_true

  app_test_helper.route(
    sockets,
    "retained",
    "[\"j2\",\"6\",\"room:lobby\",\"phx_leave\",{}]",
  )
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  app_test_helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  let assert Closed("room:lobby", socket.Normal) =
    app_test_helper.next_event(inputs)
  app_test_helper.join_ok(sockets, frames, "retained", "room:lobby", "j3", "7")
  let assert Join("room:lobby", _, _) = app_test_helper.next_event(inputs)
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(sockets, "retained", "room:lobby", "after_leave", "8")
  expect_message(handler, "text", "rate_limited", "not_applicable")
  |> should.be_true
  route_heartbeat(sockets, "retained")
  let _barrier = app_test_helper.recv(frames)
  expect_message(handler, "heartbeat", "handled", "not_applicable")
  |> should.be_true
  process.receive(inputs, 0) |> should.be_error
  expect_none(handler) |> should.be_true
  detach(handler)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn shutdown_reason_and_disabled_runtime_are_reported_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let enabled = start(telemetry_config())
  let _frames = app_test_helper.connect(enabled, "shutdown")
  expect_connected(handler) |> should.be_true
  let assert Ok(Nil) = beryl.stop(enabled)
  expect_disconnect(handler, "shutdown", 0) |> should.be_true

  let disabled = start(beryl.config(wire.phoenix_codec()))
  let disabled_frames = app_test_helper.connect(disabled, "disabled")
  app_test_helper.join(disabled, "disabled", "room:lobby", "jr-1", "1")
  let _reply = app_test_helper.recv(disabled_frames)
  route_heartbeat(disabled, "disabled")
  let _heartbeat = app_test_helper.recv(disabled_frames)
  transport.socket_disconnected(disabled, "disabled")
  expect_none(handler) |> should.be_true
  detach(handler)
  let assert Ok(Nil) = beryl.stop(disabled)
  Nil
}

fn assert_empty(sockets: beryl.Sockets) -> Nil {
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.connected_sockets(current) == 0
      && snapshot.joined_socket_topic_pairs(current) == 0
      && snapshot.active_topics(current) == 0
    },
    2000,
    10,
  )
}

fn await_actor_exit(monitor: process.Monitor) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 3000)
  Nil
}

pub fn killed_socket_reports_lifetime_and_sweeps_presence_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let actors = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(tracker) =
    presence.start(presence.default_config("lifecycle-crash"))
  let assert Ok(sockets) =
    app_test_helper.start_app(
      telemetry_config() |> beryl.with_presence_handle(tracker),
      init: fn(_info: socket.ConnectInfo(AppMessage)) {
        process.send(actors, process.self())
        #(Nil, [])
      },
      update: fn(model, input) {
        case input {
          Join(topic, _, ref) ->
            Next(model, [
              AcceptJoin(ref, None),
              socket.PresenceTrack(topic, "user", json.object([])),
            ])
          Message(..) | Binary(..) | Info(..) | Closed(..) -> Next(model, [])
        }
      },
    )
  let frames =
    app_test_helper.connect_with_close(sockets, "crash", fn() {
      process.send(closed, Nil)
    })
  let assert Ok(socket_actor) = process.receive(actors, 500)
  expect_connected(handler) |> should.be_true
  let lifetime_start = telemetry.start_time()
  app_test_helper.join(sockets, "crash", "room:crash", "jr", "1")
  let _reply = app_test_helper.recv(frames)
  let _presence = app_test_helper.recv(frames)
  expect_join(handler, "accepted") |> should.be_true
  expect_broadcast(handler, "local", 1) |> should.be_true
  test_helper.wait_until(
    fn() {
      let assert Ok(entries) = presence.list(tracker, "room:crash")
      let assert Ok(current) = snapshot.get(sockets)
      entries != [] && snapshot.joined_socket_topic_pairs(current) == 1
    },
    1000,
    10,
  )
  let minimum_duration = telemetry.duration_since(lifetime_start)
  let monitor = process.monitor(socket_actor)
  process.kill(socket_actor)
  await_actor_exit(monitor)
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  #(
    "abnormal disconnect",
    expect_disconnect_after(handler, "socket_process_down", 1, minimum_duration),
  )
  |> should.equal(#("abnormal disconnect", True))
  assert_empty(sockets)
  test_helper.wait_until(
    fn() { presence.list(tracker, "room:crash") == Ok([]) },
    1000,
    10,
  )
  transport.socket_disconnected(sockets, "crash")
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  #("no duplicate lifecycle", expect_none(handler))
  |> should.equal(#("no duplicate lifecycle", True))
  detach(handler)
}

fn drain_subject(subject: process.Subject(a)) -> Nil {
  case process.receive(subject, 0) {
    Ok(_) -> drain_subject(subject)
    Error(Nil) -> Nil
  }
}

fn normal_close_race(checkpoint: fn(RaceStage, process.Pid) -> Nil) -> Nil {
  use handler <- with_capture()
  let actors = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      telemetry_config(),
      init: fn(_info: socket.ConnectInfo(AppMessage)) {
        process.send(actors, process.self())
        #(Nil, [])
      },
      update: update,
    )
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  // Install cleanup before runtime lookup, init, or admission assertions.
  use close, release <- with_race_runtime(
    supervisor.pid,
    fn() { process.send(closed, Nil) },
    fn() {
      case beryl.stop(sockets) {
        Ok(Nil) | Error(beryl.NotRunning) -> Nil
        Error(beryl.StopTimeout) -> panic as "race fixture failed to stop"
      }
    },
    fn() {
      drain_subject(actors)
      drain_subject(closed)
    },
  )
  let router = app_test_helper.runtime_pid(sockets)
  checkpoint(RuntimeStarted, router)
  let admitted =
    transport.admit_socket(
      sockets: sockets,
      owner: router,
      socket_id: "race",
      send: fn(_) { Ok(Nil) },
      send_binary: fn(_) { Ok(Nil) },
      codec: None,
      seed: socket.empty_seed(),
      close: close,
    )
  checkpoint(Admitted, router)
  admitted |> should.equal(Ok(Nil))
  let assert Ok(socket_actor) = process.receive(actors, 500)
  expect_connected(handler) |> should.be_true
  use monitor <- with_actor_monitor(socket_actor)
  checkpoint(Connected, router)
  transport.socket_disconnected(sockets, "race")
  let assert Ok(Nil) = process.receive(closed, 500)
  with_suspended(router, fn() {
    checkpoint(Suspended, router)
    release()
    checkpoint(Released, router)
    // Queue the terminal report, close notification, and DOWN together.
    await_actor_exit(monitor)
    checkpoint(ActorExited, router)
  })
  expect_disconnect(handler, "normal", 0) |> should.be_true
  assert_empty(sockets)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  expect_none(handler) |> should.be_true
  checkpoint(Verified, router)
}

/// Exercise the close-notification/DOWN race with exception-safe ownership.
pub fn normal_close_notification_and_down_race_emit_once_test() -> Nil {
  use <- unitest.tag("serial")
  normal_close_race(fn(_, _) { Nil })
}

/// Catch assertions in the runner itself, as unitest's serial lane does.
pub fn normal_close_race_assertions_restore_cleanup_baselines_test() -> Nil {
  use <- unitest.tag("serial")
  let unrelated = process.new_subject()
  process.send(unrelated, Nil)
  use _monitor <- with_actor_monitor(process.self())
  list.each(
    [
      RuntimeStarted, Admitted, Connected, Suspended, Released, ActorExited,
      Verified,
    ],
    fn(failure_stage) {
      cleanup_baseline(fn() {
        let routers = process.new_subject()
        catch_injected_assertion(fn() {
          normal_close_race(fn(stage, router) {
            case stage == failure_stage {
              True -> {
                process.send(routers, router)
                #("injected race assertion", False)
                |> should.equal(#("injected race assertion", True))
              }
              False -> Nil
            }
          })
        })
        |> should.be_true
        let assert Ok(router) = process.receive(routers, 0)
        process.is_alive(router) |> should.be_false
      })
      |> should.be_true
    },
  )
  process.receive(unrelated, 0) |> should.equal(Ok(Nil))
}

pub fn forced_stop_drain_accounts_for_stuck_socket_once_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let actors = process.new_subject()
  let closed = process.new_subject()
  let stopped = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      telemetry_config(),
      init: fn(_info: socket.ConnectInfo(AppMessage)) {
        process.send(actors, process.self())
        #(Nil, [])
      },
      update: update,
    )
  let frames =
    app_test_helper.connect_with_close(sockets, "stuck", fn() {
      process.send(closed, Nil)
    })
  let assert Ok(socket_actor) = process.receive(actors, 500)
  expect_connected(handler) |> should.be_true
  app_test_helper.join(sockets, "stuck", "room:stuck", "jr", "1")
  let _reply = app_test_helper.recv(frames)
  expect_join(handler, "accepted") |> should.be_true
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = snapshot.get(sockets)
      snapshot.joined_socket_topic_pairs(current) == 1
    },
    1000,
    10,
  )
  let monitor = process.monitor(socket_actor)
  // Suspension holds phase one until the router's forced-drain deadline.
  test_helper.suspend_process(socket_actor)
  let _stopper =
    process.spawn(fn() { process.send(stopped, beryl.stop(sockets)) })
  process.receive(stopped, 4000)
  |> should.equal(Ok(Error(beryl.StopTimeout)))
  await_actor_exit(monitor)
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  expect_disconnect(handler, "shutdown", 1) |> should.be_true
  expect_none(handler) |> should.be_true
  detach(handler)
}

pub fn heartbeat_and_callback_stop_preserve_terminal_reasons_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let heartbeat =
    start(telemetry_config() |> beryl.with_heartbeat(timeout_ms: 40))
  let heartbeat_frames = app_test_helper.connect(heartbeat, "heartbeat")
  expect_connected(handler) |> should.be_true
  app_test_helper.join(heartbeat, "heartbeat", "room:a", "jr", "1")
  let _reply = app_test_helper.recv(heartbeat_frames)
  expect_join(handler, "accepted") |> should.be_true
  expect_disconnect(handler, "heartbeat_timeout", 1) |> should.be_true
  let _close = app_test_helper.recv(heartbeat_frames)
  assert_empty(heartbeat)
  beryl.stop(heartbeat) |> should.equal(Ok(Nil))

  let callback = start(telemetry_config())
  let callback_frames = app_test_helper.connect(callback, "callback")
  expect_connected(handler) |> should.be_true
  app_test_helper.join(callback, "callback", "room:a", "jr", "1")
  let _reply = app_test_helper.recv(callback_frames)
  expect_join(handler, "accepted") |> should.be_true
  app_test_helper.push(callback, "callback", "room:a", "stop", "2")
  expect_message(handler, "text", "handled", "stop") |> should.be_true
  expect_disconnect(handler, "callback_error", 1) |> should.be_true
  let _close = app_test_helper.recv(callback_frames)
  assert_empty(callback)
  beryl.stop(callback) |> should.equal(Ok(Nil))
  expect_none(handler) |> should.be_true
  detach(handler)
}

fn admit(sockets: beryl.Sockets, socket_id: String) -> Result(Nil, Nil) {
  transport.admit_socket(
    sockets: sockets,
    owner: app_test_helper.runtime_pid(sockets),
    socket_id: socket_id,
    send: fn(_) { Ok(Nil) },
    send_binary: fn(_) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
}

pub fn failed_and_abandoned_admission_have_no_lifecycle_events_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let failed =
    app_test_helper.start_app(
      telemetry_config(),
      init: fn(_info: socket.ConnectInfo(AppMessage)) {
        panic as "expected admission failure"
      },
      update: update,
    )
  let assert Ok(failed) = failed
  admit(failed, "failed") |> should.equal(Error(Nil))
  assert_empty(failed)
  beryl.stop(failed) |> should.equal(Ok(Nil))
  expect_none(handler) |> should.be_true

  let booting = process.new_subject()
  let assert Ok(abandoned) =
    app_test_helper.start_app(
      telemetry_config(),
      init: fn(_info: socket.ConnectInfo(AppMessage)) {
        let release = process.new_subject()
        process.send(booting, process.self())
        let assert Ok(Nil) = process.receive(release, 5000)
        #(Nil, [])
      },
      update: update,
    )
  let connection =
    process.spawn_unlinked(fn() {
      let _result = admit(abandoned, "abandoned")
      Nil
    })
  let assert Ok(socket_actor) = process.receive(booting, 500)
  let monitor = process.monitor(socket_actor)
  process.kill(connection)
  await_actor_exit(monitor)
  assert_empty(abandoned)
  beryl.stop(abandoned) |> should.equal(Ok(Nil))
  expect_none(handler) |> should.be_true
  detach(handler)
}

pub fn disabled_telemetry_does_not_report_socket_crashes_test() -> Nil {
  use <- unitest.tag("serial")
  let handler = attach()
  let actors = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: socket.ConnectInfo(AppMessage)) {
        process.send(actors, process.self())
        #(Nil, [])
      },
      update: update,
    )
  let _frames =
    app_test_helper.connect_with_close(sockets, "disabled-crash", fn() {
      process.send(closed, Nil)
    })
  let assert Ok(socket_actor) = process.receive(actors, 500)
  let monitor = process.monitor(socket_actor)
  process.kill(socket_actor)
  await_actor_exit(monitor)
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  assert_empty(sockets)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  expect_none(handler) |> should.be_true
  detach(handler)
}
