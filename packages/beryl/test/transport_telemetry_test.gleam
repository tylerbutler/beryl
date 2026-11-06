//// Downstream-style transport coverage: only public beryl APIs are imported.
//// Transport events are synchronous in this owner; runtime events are excluded
//// by both the event names and the emitting-process filter in the capture.

import beryl
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import unitest

type TelemetryHandle

@external(erlang, "beryl_telemetry_test_ffi", "attach_transport")
fn attach_transport() -> TelemetryHandle

@external(erlang, "beryl_telemetry_test_ffi", "detach")
fn detach(handler: TelemetryHandle) -> Nil

@external(erlang, "beryl_telemetry_test_ffi", "receive_upgrade")
fn receive_upgrade(
  handler: TelemetryHandle,
) -> Result(#(Int, Int, String, String), Nil)

@external(erlang, "beryl_telemetry_test_ffi", "receive_frame")
fn receive_frame(
  handler: TelemetryHandle,
) -> Result(#(Int, Int, Int, String, String, String), Nil)

@external(erlang, "beryl_telemetry_test_ffi", "no_transport_events")
fn no_transport_events(handler: TelemetryHandle) -> Bool

fn start_system(
  enabled: Bool,
  joined: process.Subject(String),
) -> beryl.Sockets {
  let config = beryl.config(wire.phoenix_codec())
  let config = case enabled {
    True -> beryl.with_telemetry(config)
    False -> config
  }
  let assert Ok(#(sockets, specification)) =
    beryl.child_spec(
      config,
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, input) {
        case input {
          socket.Join(topic, _payload, reference) -> {
            process.send(joined, topic)
            socket.Next(model, [socket.AcceptJoin(reference, None)])
          }
          socket.Message(..)
          | socket.Binary(..)
          | socket.Closed(..)
          | socket.Info(..) -> socket.Next(model, [])
        }
      },
    )
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(specification)
    |> static_supervisor.start()
  sockets
}

fn assert_upgrade(
  handler: TelemetryHandle,
  label: String,
  outcome: String,
) -> Nil {
  let assert Ok(#(count, duration, actual_label, actual_outcome)) =
    receive_upgrade(handler)
  count |> should.equal(1)
  should.be_true(duration >= 0)
  actual_label |> should.equal(label)
  actual_outcome |> should.equal(outcome)
}

fn assert_frame(
  handler: TelemetryHandle,
  label: String,
  bytes: Int,
  kind: String,
) -> Nil {
  let assert Ok(#(
    count,
    duration,
    actual_bytes,
    actual_label,
    actual_kind,
    outcome,
  )) = receive_frame(handler)
  count |> should.equal(1)
  should.be_true(duration >= 0)
  actual_bytes |> should.equal(bytes)
  actual_label |> should.equal(label)
  actual_kind |> should.equal(kind)
  outcome |> should.equal("routed")
}

fn exercise_shared_pipeline(enabled: Bool) -> Nil {
  let joined = process.new_subject()
  let sockets = start_system(enabled, joined)
  let telemetry = transport.telemetry(sockets, transport.Custom)
  let handler = attach_transport()
  case enabled {
    True -> Nil
    False -> transport.telemetry_start(telemetry) |> should.equal(0)
  }
  let config = server.default_config("/socket")
  let assert Ok(upgrade_request) =
    request.to("http://localhost/socket?vsn=2.0.0")
  let admitted = process.new_subject()
  server.upgrade(
    request: upgrade_request,
    sockets: sockets,
    config: config,
    telemetry: telemetry,
    request_ip: fn(_) { Ok("127.0.0.1") },
    reject: fn(status) { response.new(status) },
    accept: fn(metadata, permit) {
      metadata |> should.equal([])
      process.send(admitted, permit)
      response.new(101)
    },
    next: fn() { response.new(404) },
  ).status
  |> should.equal(101)
  let assert Ok(permit) = process.receive(admitted, 500)

  // The rejection must not call accept (which would enqueue another permit).
  server.upgrade(
    request: request.set_header(
      upgrade_request,
      "origin",
      "https://other.example",
    ),
    sockets: sockets,
    config: config,
    telemetry: telemetry,
    request_ip: fn(_) { Ok("127.0.0.1") },
    reject: fn(status) { response.new(status) },
    accept: fn(_metadata, permit) {
      process.send(admitted, permit)
      response.new(101)
    },
    next: fn() { response.new(404) },
  ).status
  |> should.equal(403)
  process.receive(admitted, 0) |> should.equal(Error(Nil))

  let #(state, selector) =
    server.init_connection(
      sockets: sockets,
      seed: socket.empty_seed(),
      connection_permit: permit,
      base_selector: process.new_selector(),
      config: config,
      force_close: fn() { Ok(Nil) },
      logger_name: "transport_telemetry_test",
      telemetry: telemetry,
      codec: None,
    )
  let heartbeat = "[null,\"heartbeat-ref\",\"phoenix\",\"heartbeat\",{}]"
  let assert server.Continue(state) = server.handle_text_frame(state, heartbeat)
  let assert Ok(server.SendText(reply, bytes)) =
    process.selector_receive(selector, 500)
  reply
  |> should.equal(
    "[null,\"heartbeat-ref\",\"phoenix\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  )
  let assert server.Continue(state) =
    server.finish_outbound_write(state, bytes, Ok(Nil))

  // Phoenix V2 client push: kind, four field lengths, fields, raw payload.
  // A binary join reaches the normal app callback and produces a join reply.
  let binary = <<
    0,
    1,
    1,
    10,
    8,
    "j":utf8,
    "1":utf8,
    "room:lobby":utf8,
    "phx_join":utf8,
  >>
  let assert server.Continue(state) = server.handle_binary_frame(state, binary)
  process.receive(joined, 500) |> should.equal(Ok("room:lobby"))
  let assert Ok(server.SendText(join_reply, bytes)) =
    process.selector_receive(selector, 500)
  join_reply
  |> should.equal(
    "[\"j\",\"1\",\"room:lobby\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  )
  let assert server.Continue(state) =
    server.finish_outbound_write(state, bytes, Ok(Nil))

  server.close_connection(state)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  case enabled {
    True -> {
      assert_upgrade(handler, "custom", "success")
      assert_upgrade(handler, "custom", "origin_rejected")
      assert_frame(handler, "custom", string.byte_size(heartbeat), "text")
      assert_frame(handler, "custom", bit_array.byte_size(binary), "binary")
    }
    False -> Nil
  }
  no_transport_events(handler) |> should.be_true
  detach(handler)
}

pub fn custom_enabled_shared_pipeline_test() -> Nil {
  use <- unitest.tag("serial")
  exercise_shared_pipeline(True)
}

pub fn custom_disabled_shared_pipeline_test() -> Nil {
  use <- unitest.tag("serial")
  exercise_shared_pipeline(False)
}

pub fn built_in_public_telemetry_labels_test() -> Nil {
  use <- unitest.tag("serial")
  let sockets = start_system(True, process.new_subject())
  let handler = attach_transport()
  assert_public_label(sockets, handler, transport.Mist, "mist")
  assert_public_label(sockets, handler, transport.Ewe, "ewe")
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  no_transport_events(handler) |> should.be_true
  detach(handler)
}

fn assert_public_label(
  sockets: beryl.Sockets,
  handler: TelemetryHandle,
  kind: transport.TelemetryTransport,
  label: String,
) -> Nil {
  let telemetry = transport.telemetry(sockets, kind)
  transport.telemetry_upgrade_stop(
    telemetry,
    transport.telemetry_start(telemetry),
    transport.UpgradeSucceeded,
  )
  transport.telemetry_frame_stop(
    telemetry,
    transport.telemetry_start(telemetry),
    7,
    transport.TextFrame,
    transport.FrameRouted,
  )
  assert_upgrade(handler, label, "success")
  assert_frame(handler, label, 7, "text")
}
