import beryl/overload
import beryl/telemetry
import beryl/work_queue
import gleeunit/should

/// Opaque handle to an attached :telemetry handler, produced and consumed
/// only by the test FFI — never inspected from Gleam.
type TelemetryHandle

@external(erlang, "beryl_telemetry_test_ffi", "attach_socket_connected")
fn attach_socket_connected() -> TelemetryHandle

@external(erlang, "beryl_telemetry_test_ffi", "detach")
fn detach(handler_id: TelemetryHandle) -> Nil

@external(erlang, "beryl_telemetry_test_ffi", "received_socket_connected")
fn received_socket_connected() -> Bool

@external(erlang, "beryl_telemetry_test_ffi", "attach_queue")
fn attach_queue() -> TelemetryHandle

type QueueLabel {
  Changed
  Rejected
}

@external(erlang, "beryl_telemetry_test_ffi", "assert_queue_event")
fn assert_queue_event(
  items: Int,
  rejected: Int,
  cancelled: Int,
  outcome: QueueLabel,
) -> Nil

@external(erlang, "beryl_telemetry_test_ffi", "assert_no_queue_event")
fn assert_no_queue_event() -> Nil

pub fn queue_events_match_admission_and_cancellation_test() -> Nil {
  let handler = attach_queue()
  let assert Ok(limits) = overload.limits(items: 1, bytes: 8)
  let queue = work_queue.new(limits, overload.WorkerQueue, True, fn() { Nil })
  let assert Ok(reservation) = work_queue.publish_value(queue, Nil)
  assert_queue_event(1, 0, 0, Changed)
  let assert Error(_) = work_queue.publish_value(queue, Nil)
  assert_queue_event(1, 1, 0, Rejected)
  work_queue.release(queue, reservation)
  assert_queue_event(0, 1, 1, Changed)
  let assert Ok(snapshot) = work_queue.snapshot(queue)
  telemetry.emit(
    True,
    telemetry.QueueOccupancy(snapshot, telemetry.QueueChanged),
  )
  assert_queue_event(0, 1, 1, Changed)
  telemetry.emit(
    False,
    telemetry.QueueOccupancy(snapshot, telemetry.QueueRejected),
  )
  assert_no_queue_event()
  detach(handler)
}

pub fn disabled_queue_does_not_emit_test() -> Nil {
  let handler = attach_queue()
  let assert Ok(limits) = overload.limits(items: 1, bytes: 8)
  let queue = work_queue.new(limits, overload.WorkerQueue, False, fn() { Nil })
  let assert Ok(reservation) = work_queue.publish_value(queue, Nil)
  let assert Error(_) = work_queue.publish_value(queue, Nil)
  work_queue.release(queue, reservation)
  assert_no_queue_event()
  detach(handler)
}

pub fn telemetry_clock_returns_non_negative_duration_test() -> Nil {
  let started_at = telemetry.start_time()

  telemetry.duration_since(started_at)
  |> fn(duration) { duration >= 0 }
  |> should.be_true
}

pub fn mailbox_length_is_non_negative_test() -> Nil {
  telemetry.mailbox_length()
  |> fn(length) { length >= 0 }
  |> should.be_true
}

pub fn enabled_emit_executes_typed_event_test() -> Nil {
  let handler_id = attach_socket_connected()
  telemetry.emit(True, telemetry.SocketConnected)
  |> should.equal(Nil)
  let received = received_socket_connected()
  detach(handler_id)

  received
  |> should.be_true
}

pub fn disabled_emit_does_not_execute_event_test() -> Nil {
  let handler_id = attach_socket_connected()
  telemetry.emit(False, telemetry.SocketConnected)
  let received = received_socket_connected()
  detach(handler_id)

  received
  |> should.be_false
}
