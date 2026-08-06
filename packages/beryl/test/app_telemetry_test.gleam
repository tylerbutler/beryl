import app_test_helpers as h
import beryl
import beryl/event.{
  AcceptJoin, Binary, Info, Join, Message, Next, Push, RejectJoin, ReplyError,
  ReplyOk,
}
import beryl/pubsub
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

@external(erlang, "beryl_runtime_telemetry_test_ffi", "attach")
fn attach() -> Dynamic

@external(erlang, "beryl_runtime_telemetry_test_ffi", "detach")
fn detach(handler_id: Dynamic) -> Nil

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_connected")
fn expect_connected(handler_id: Dynamic) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_join")
fn expect_join(handler_id: Dynamic, outcome: String) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_message")
fn expect_message(
  handler_id: Dynamic,
  kind: String,
  outcome: String,
  callback_result: String,
) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_disconnect")
fn expect_disconnect(
  handler_id: Dynamic,
  reason: String,
  joined_channels: Int,
) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_broadcast")
fn expect_broadcast(
  handler_id: Dynamic,
  origin: String,
  recipients: Int,
  send_failures: Int,
) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_none")
fn expect_none(handler_id: Dynamic) -> Bool

pub fn main() {
  gleeunit.main()
}

type AppMessage {
  Tick
}

fn telemetry_config() -> beryl.Config {
  beryl.config(wire.phoenix_codec())
  |> beryl.with_telemetry
}

fn update(model: Nil, input: event.Input(AppMessage)) {
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
    Message(_, "crash", _, _) -> panic as "expected message failure"
    Message(_, _, _, _) | Binary(_, _) | Info(_) -> Next(model, [])
    _ -> Next(model, [])
  }
}

fn start(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(sockets) =
    h.start_app(
      config,
      init: fn(_info: event.ConnectInfo(AppMessage)) { #(Nil, []) },
      update: update,
    )
  sockets
}

fn route_heartbeat(sockets: beryl.Sockets, socket_id: String) -> Nil {
  h.route(
    sockets,
    socket_id,
    "[null,\"heartbeat-ref\",\"phoenix\",\"heartbeat\",{}]",
  )
}

pub fn lifecycle_and_callback_results_emit_once_test() {
  let handler = attach()
  let sockets = start(telemetry_config())
  let frames = h.connect(sockets, "socket-1")
  expect_connected(handler) |> should.be_true

  h.join(sockets, "socket-1", "room:lobby", "join-ref", "1")
  let _join_reply = h.recv(frames)
  expect_join(handler, "accepted") |> should.be_true

  h.push(sockets, "socket-1", "room:lobby", "noop", "2")
  expect_message(handler, "text", "handled", "no_reply") |> should.be_true

  h.push(sockets, "socket-1", "room:lobby", "reply", "3")
  let _reply = h.recv(frames)
  expect_message(handler, "text", "handled", "reply") |> should.be_true

  h.push(sockets, "socket-1", "room:lobby", "reply_error", "4")
  let _error_reply = h.recv(frames)
  expect_message(handler, "text", "handled", "reply_error") |> should.be_true

  h.push(sockets, "socket-1", "room:lobby", "push", "5")
  let _push = h.recv(frames)
  expect_message(handler, "text", "handled", "push") |> should.be_true

  route_heartbeat(sockets, "socket-1")
  let _heartbeat_reply = h.recv(frames)
  expect_message(handler, "heartbeat", "handled", "not_applicable")
  |> should.be_true

  transport.socket_disconnected(sockets, "socket-1")
  expect_disconnect(handler, "normal", 1) |> should.be_true
  expect_none(handler) |> should.be_true
  detach(handler)
  let assert Ok(Nil) = beryl.stop(sockets)
}

pub fn join_terminal_outcomes_are_reported_test() {
  let handler = attach()
  let sockets = start(telemetry_config())
  let frames = h.connect(sockets, "join-outcomes")
  expect_connected(handler) |> should.be_true

  h.join(sockets, "join-outcomes", "room:reject", "jr-1", "1")
  let _rejected = h.recv(frames)
  expect_join(handler, "handler_rejected") |> should.be_true

  h.join(sockets, "join-outcomes", "beryl:reserved", "jr-2", "2")
  let _invalid = h.recv(frames)
  expect_join(handler, "invalid_topic") |> should.be_true

  h.join(sockets, "join-outcomes", "room:crash", "jr-3", "3")
  let _crashed = h.recv(frames)
  expect_join(handler, "callback_error") |> should.be_true

  let limited =
    start(
      telemetry_config()
      |> beryl.with_join_rate(per_second: 1, burst: 1),
    )
  let limited_frames = h.connect(limited, "limited")
  expect_connected(handler) |> should.be_true
  h.join(limited, "limited", "room:first", "jr-1", "1")
  let _accepted = h.recv(limited_frames)
  expect_join(handler, "accepted") |> should.be_true
  h.join(limited, "limited", "room:second", "jr-2", "2")
  let _rate_limited = h.recv(limited_frames)
  expect_join(handler, "rate_limited") |> should.be_true

  expect_none(handler) |> should.be_true
  detach(handler)
}

pub fn message_rejection_rate_limit_and_crash_are_terminal_test() {
  let handler = attach()
  let limited =
    start(
      telemetry_config()
      |> beryl.with_message_rate(per_second: 1, burst: 1),
    )
  let frames = h.connect(limited, "limited")
  expect_connected(handler) |> should.be_true

  h.push(limited, "limited", "room:lobby", "noop", "1")
  let _unmatched = h.recv(frames)
  expect_message(handler, "text", "unjoined", "not_applicable")
  |> should.be_true
  h.push(limited, "limited", "room:lobby", "noop", "2")
  expect_message(handler, "text", "rate_limited", "not_applicable")
  |> should.be_true

  let crashed = start(telemetry_config())
  let crashed_frames = h.connect(crashed, "crashed")
  expect_connected(handler) |> should.be_true
  h.join(crashed, "crashed", "room:lobby", "jr-1", "1")
  let _joined = h.recv(crashed_frames)
  expect_join(handler, "accepted") |> should.be_true
  h.push(crashed, "crashed", "room:lobby", "crash", "2")
  expect_message(handler, "text", "callback_error", "failed")
  |> should.be_true

  expect_none(handler) |> should.be_true
  detach(handler)
}

pub fn decoded_binary_route_preserves_message_kind_test() {
  let handler = attach()
  let sockets = start(telemetry_config())
  let frames = h.connect(sockets, "decoded-binary")
  expect_connected(handler) |> should.be_true

  h.join(sockets, "decoded-binary", "room:lobby", "join-ref", "1")
  let _joined = h.recv(frames)
  expect_join(handler, "accepted") |> should.be_true

  let text_event = "[\"join-ref\",\"text-ref\",\"room:lobby\",\"noop\",{}]"
  let assert Ok(text_message) =
    codec.decode_text(transport.active_codec(sockets))(text_event)
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
  transport.route_decoded_binary(sockets, "decoded-binary", binary_message)
  expect_message(handler, "binary", "handled", "no_reply") |> should.be_true

  expect_none(handler) |> should.be_true
  detach(handler)
  let assert Ok(Nil) = beryl.stop(sockets)
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

pub fn binary_info_and_broadcast_counts_are_reported_test() {
  let handler = attach()
  let ps = pubsub.start(pubsub.default_config())
  let senders = process.new_subject()
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(raw_binary_codec())
        |> beryl.with_pubsub(ps)
        |> beryl.with_telemetry,
      init: fn(info: event.ConnectInfo(AppMessage)) {
        process.send(senders, info.self)
        #(Nil, [])
      },
      update: update,
    )
  let frames = h.connect(sockets, "ok")
  let assert Ok(sender) = process.receive(senders, 500)
  expect_connected(handler) |> should.be_true
  h.join(sockets, "ok", "room:lobby", "jr-1", "1")
  let _joined = h.recv(frames)
  expect_join(handler, "accepted") |> should.be_true

  transport.route_binary(sockets, "ok", <<1, 2, 3>>)
  expect_message(handler, "binary", "handled", "no_reply") |> should.be_true
  event.notify(sender, Tick)
  expect_message(handler, "info", "handled", "no_reply") |> should.be_true

  beryl.broadcast(sockets, "room:lobby", "event", json.object([]))
  let _local = h.recv(frames)
  expect_broadcast(handler, "local", 1, 0) |> should.be_true

  pubsub.broadcast(ps, "room:lobby", "remote", json.object([]))
  let _remote = h.recv(frames)
  expect_broadcast(handler, "remote", 1, 0) |> should.be_true

  expect_none(handler) |> should.be_true
  detach(handler)
}

pub fn shutdown_reason_and_disabled_runtime_are_reported_test() {
  let handler = attach()
  let enabled = start(telemetry_config())
  let _frames = h.connect(enabled, "shutdown")
  expect_connected(handler) |> should.be_true
  let assert Ok(Nil) = beryl.stop(enabled)
  expect_disconnect(handler, "shutdown", 0) |> should.be_true

  let disabled = start(beryl.config(wire.phoenix_codec()))
  let disabled_frames = h.connect(disabled, "disabled")
  h.join(disabled, "disabled", "room:lobby", "jr-1", "1")
  let _reply = h.recv(disabled_frames)
  route_heartbeat(disabled, "disabled")
  let _heartbeat = h.recv(disabled_frames)
  transport.socket_disconnected(disabled, "disabled")
  expect_none(handler) |> should.be_true
  detach(handler)
  let assert Ok(Nil) = beryl.stop(disabled)
}
