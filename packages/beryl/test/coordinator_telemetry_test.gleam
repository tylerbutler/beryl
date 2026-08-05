import beryl/coordinator
import beryl/pubsub
import beryl/rate_limit
import beryl/topic
import beryl/wire
import beryl/wire/codec
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import test_helpers

@external(erlang, "beryl_coordinator_telemetry_test_ffi", "attach")
fn attach() -> Dynamic

@external(erlang, "beryl_coordinator_telemetry_test_ffi", "detach")
fn detach(handler_id: Dynamic) -> Nil

@external(erlang, "beryl_coordinator_telemetry_test_ffi", "expect_connected")
fn expect_connected(handler_id: Dynamic) -> Bool

@external(erlang, "beryl_coordinator_telemetry_test_ffi", "expect_join")
fn expect_join(handler_id: Dynamic, outcome: String) -> Bool

@external(erlang, "beryl_coordinator_telemetry_test_ffi", "expect_message")
fn expect_message(
  handler_id: Dynamic,
  kind: String,
  outcome: String,
  callback_result: String,
) -> Bool

@external(erlang, "beryl_coordinator_telemetry_test_ffi", "expect_disconnect")
fn expect_disconnect(
  handler_id: Dynamic,
  reason: String,
  joined_channels: Int,
) -> Bool

@external(erlang, "beryl_coordinator_telemetry_test_ffi", "expect_broadcast")
fn expect_broadcast(
  handler_id: Dynamic,
  origin: String,
  recipients: Int,
  send_failures: Int,
) -> Bool

@external(erlang, "beryl_coordinator_telemetry_test_ffi", "expect_none")
fn expect_none(handler_id: Dynamic) -> Bool

pub fn main() {
  gleeunit.main()
}

fn telemetry_config() -> coordinator.CoordinatorConfig {
  coordinator.CoordinatorConfig(
    ..coordinator.config(wire.phoenix_codec()),
    telemetry: True,
  )
}

fn raw_binary_telemetry_config() -> coordinator.CoordinatorConfig {
  let raw_binary_codec =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: wire.reply_json,
      encode_push: wire.push,
      encode_heartbeat_reply: wire.heartbeat_reply,
    )
    |> codec.with_close_encoder(wire.channel_close)
    |> codec.with_error_encoder(wire.channel_error)
  coordinator.CoordinatorConfig(
    ..coordinator.config(raw_binary_codec),
    telemetry: True,
  )
}

fn start(
  config: coordinator.CoordinatorConfig,
) -> process.Subject(coordinator.Message) {
  let assert Ok(coord) = coordinator.start_with_config(config)
  coord
}

fn register(
  coord: process.Subject(coordinator.Message),
  handler: coordinator.ChannelHandler,
) -> Int {
  let reply = process.new_subject()
  process.send(coord, coordinator.RegisterChannel("room:*", handler, reply))
  let assert Ok(Ok(id)) = process.receive(reply, 500)
  id
}

fn accepting_handler() -> coordinator.ChannelHandler {
  coordinator.ChannelHandler(
    id: 0,
    pattern: topic.parse_pattern("room:*"),
    join: fn(_topic, _payload, _assigns, _ctx) {
      coordinator.JoinOkErased(None, test_helpers.noop_instance())
    },
  )
}

fn connect(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
) -> Nil {
  process.send(
    coord,
    coordinator.SocketConnected(
      socket_id,
      send,
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
}

fn join(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
  topic_name: String,
) -> Nil {
  coordinator.route_message(
    coord,
    socket_id,
    "[null,\"join-ref\",\"" <> topic_name <> "\",\"phx_join\",{}]",
  )
}

fn event(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
) -> Nil {
  coordinator.route_message(
    coord,
    socket_id,
    "[\"join-ref\",\"event-ref\",\"room:lobby\",\"ping\",{}]",
  )
}

fn heartbeat(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
) -> Nil {
  coordinator.route_message(
    coord,
    socket_id,
    "[null,\"heartbeat-ref\",\"phoenix\",\"heartbeat\",{}]",
  )
}

fn ok_send(_message: String) -> Result(Nil, Nil) {
  Ok(Nil)
}

pub fn lifecycle_join_message_heartbeat_and_disconnect_emit_once_test() {
  let handler_id = attach()
  let coord = start(telemetry_config())
  let _channel_id = register(coord, accepting_handler())

  connect(coord, "socket-1", ok_send)
  expect_connected(handler_id) |> should.be_true
  join(coord, "socket-1", "room:lobby")
  expect_join(handler_id, "accepted") |> should.be_true
  event(coord, "socket-1")
  expect_message(handler_id, "text", "handled", "no_reply")
  |> should.be_true
  heartbeat(coord, "socket-1")
  expect_message(handler_id, "heartbeat", "handled", "not_applicable")
  |> should.be_true
  process.send(coord, coordinator.SocketDisconnected("socket-1"))
  expect_disconnect(handler_id, "normal", 1) |> should.be_true
  expect_none(handler_id) |> should.be_true
  detach(handler_id)
}

pub fn join_rejection_rate_limit_and_callback_failure_are_terminal_test() {
  let handler_id = attach()

  let rejected = start(telemetry_config())
  let _ =
    register(
      rejected,
      coordinator.ChannelHandler(
        id: 0,
        pattern: topic.parse_pattern("room:*"),
        join: fn(_topic, _payload, _assigns, _ctx) {
          coordinator.JoinErrorErased(json.object([]))
        },
      ),
    )
  connect(rejected, "rejected", ok_send)
  expect_connected(handler_id) |> should.be_true
  join(rejected, "rejected", "room:lobby")
  expect_join(handler_id, "handler_rejected") |> should.be_true

  let limited =
    start(
      coordinator.CoordinatorConfig(
        ..telemetry_config(),
        join_limits: Some(rate_limit.config(per_second: 1, burst: 1)),
      ),
    )
  let _ = register(limited, accepting_handler())
  connect(limited, "limited", ok_send)
  expect_connected(handler_id) |> should.be_true
  join(limited, "limited", "room:one")
  expect_join(handler_id, "accepted") |> should.be_true
  join(limited, "limited", "room:two")
  expect_join(handler_id, "rate_limited") |> should.be_true

  let crashed = start(telemetry_config())
  let _ =
    register(
      crashed,
      coordinator.ChannelHandler(
        id: 0,
        pattern: topic.parse_pattern("room:*"),
        join: fn(_topic, _payload, _assigns, _ctx) {
          panic as "expected join callback failure"
        },
      ),
    )
  connect(crashed, "crashed", ok_send)
  expect_connected(handler_id) |> should.be_true
  join(crashed, "crashed", "room:lobby")
  expect_join(handler_id, "callback_error") |> should.be_true
  expect_none(handler_id) |> should.be_true
  detach(handler_id)
}

fn crashing_instance() -> coordinator.JoinedChannel {
  coordinator.JoinedChannel(
    handle_in: fn(_event, _payload, _ctx) {
      panic as "expected message callback failure"
    },
    handle_binary: fn(_data, _ctx) {
      coordinator.NoReplyErased(crashing_instance())
    },
    handle_info: fn(_message, _ctx) {
      coordinator.NoReplyErased(crashing_instance())
    },
    terminate: fn(_reason, _ctx) { Nil },
  )
}

pub fn message_rejection_rate_limit_and_callback_failure_emit_once_test() {
  let handler_id = attach()
  let coord =
    start(
      coordinator.CoordinatorConfig(
        ..telemetry_config(),
        message_limits: Some(rate_limit.config(per_second: 1, burst: 1)),
      ),
    )
  let _ = register(coord, accepting_handler())
  connect(coord, "limited", ok_send)
  expect_connected(handler_id) |> should.be_true

  event(coord, "limited")
  expect_message(handler_id, "text", "unjoined", "not_applicable")
  |> should.be_true
  event(coord, "limited")
  expect_message(handler_id, "text", "rate_limited", "not_applicable")
  |> should.be_true

  let crashed = start(telemetry_config())
  let _ =
    register(
      crashed,
      coordinator.ChannelHandler(
        id: 0,
        pattern: topic.parse_pattern("room:*"),
        join: fn(_topic, _payload, _assigns, _ctx) {
          coordinator.JoinOkErased(None, crashing_instance())
        },
      ),
    )
  connect(crashed, "crashed", ok_send)
  expect_connected(handler_id) |> should.be_true
  join(crashed, "crashed", "room:lobby")
  expect_join(handler_id, "accepted") |> should.be_true
  event(crashed, "crashed")
  expect_message(handler_id, "text", "callback_error", "failed")
  |> should.be_true
  expect_none(handler_id) |> should.be_true
  detach(handler_id)
}

pub fn binary_info_and_broadcast_counts_are_reported_test() {
  let handler_id = attach()
  let coord = start(raw_binary_telemetry_config())
  let channel_id = register(coord, accepting_handler())
  connect(coord, "ok", ok_send)
  expect_connected(handler_id) |> should.be_true
  join(coord, "ok", "room:lobby")
  expect_join(handler_id, "accepted") |> should.be_true

  coordinator.route_binary(coord, "ok", <<1, 2, 3>>)
  expect_message(handler_id, "binary", "handled", "no_reply")
  |> should.be_true
  process.send(
    coord,
    coordinator.HandleInfo("ok", "room:lobby", channel_id, dynamic.nil()),
  )
  expect_message(handler_id, "info", "handled", "no_reply")
  |> should.be_true

  connect(coord, "failed", fn(_) { Error(Nil) })
  expect_connected(handler_id) |> should.be_true
  join(coord, "failed", "room:lobby")
  expect_join(handler_id, "accepted") |> should.be_true
  process.send(
    coord,
    coordinator.Broadcast("room:lobby", "event", json.object([]), None),
  )
  expect_broadcast(handler_id, "local", 2, 1) |> should.be_true
  process.send(
    coord,
    coordinator.RemoteBroadcast(pubsub.Message(
      "room:lobby",
      "event",
      json.object([]),
      pubsub.System,
    )),
  )
  expect_broadcast(handler_id, "remote", 2, 1) |> should.be_true
  expect_none(handler_id) |> should.be_true
  detach(handler_id)
}

pub fn heartbeat_timeout_and_shutdown_disconnect_reasons_test() {
  let handler_id = attach()
  let timed_out =
    start(
      coordinator.CoordinatorConfig(
        ..telemetry_config(),
        heartbeat_timeout_ms: 1,
      ),
    )
  connect(timed_out, "stale", ok_send)
  expect_connected(handler_id) |> should.be_true
  process.sleep(5)
  process.send(timed_out, coordinator.CheckHeartbeats)
  expect_disconnect(handler_id, "heartbeat_timeout", 0) |> should.be_true

  let stopped = start(telemetry_config())
  connect(stopped, "shutdown", ok_send)
  expect_connected(handler_id) |> should.be_true
  let reply = process.new_subject()
  process.send(stopped, coordinator.Stop(reply))
  expect_disconnect(handler_id, "shutdown", 0) |> should.be_true
  let assert Ok(Nil) = process.receive(reply, 500)
  expect_none(handler_id) |> should.be_true
  detach(handler_id)
}

pub fn disabled_coordinator_telemetry_emits_nothing_test() {
  let handler_id = attach()
  let coord = start(coordinator.config(wire.phoenix_codec()))
  connect(coord, "disabled", ok_send)
  heartbeat(coord, "disabled")
  process.send(coord, coordinator.SocketDisconnected("disabled"))
  process.sleep(25)
  expect_none(handler_id) |> should.be_true
  detach(handler_id)
}
