import beryl/telemetry
import gleam/dynamic.{type Dynamic}
import gleeunit
import gleeunit/should

@external(erlang, "beryl_telemetry_test_ffi", "attach_socket_connected")
fn attach_socket_connected() -> Dynamic

@external(erlang, "beryl_telemetry_test_ffi", "detach")
fn detach(handler_id: Dynamic) -> Nil

@external(erlang, "beryl_telemetry_test_ffi", "received_socket_connected")
fn received_socket_connected() -> Bool

pub fn main() {
  gleeunit.main()
}

pub fn telemetry_clock_returns_non_negative_duration_test() {
  let started_at = telemetry.start_time()

  telemetry.duration_since(started_at)
  |> fn(duration) { duration >= 0 }
  |> should.be_true
}

pub fn mailbox_length_is_non_negative_test() {
  telemetry.mailbox_length()
  |> fn(length) { length >= 0 }
  |> should.be_true
}

pub fn enabled_emit_executes_typed_event_test() {
  let handler_id = attach_socket_connected()
  telemetry.emit(True, telemetry.SocketConnected)
  |> should.equal(Nil)
  let received = received_socket_connected()
  detach(handler_id)

  received
  |> should.be_true
}

pub fn disabled_emit_does_not_execute_event_test() {
  let handler_id = attach_socket_connected()
  telemetry.emit(False, telemetry.SocketConnected)
  let received = received_socket_connected()
  detach(handler_id)

  received
  |> should.be_false
}
