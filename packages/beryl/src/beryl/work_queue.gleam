//// Owner-scoped, bounded local work publication.
////
//// Publishing the payload and reserving capacity is one ETS operation.
//// Wake messages are coalesced. Owners must also check the queue on their
//// recovery tick: a publisher can stop after publication but before waking.

import beryl/overload.{
  type AdmissionError, type Boundary, type Limits, type Occupancy,
}
import gleam/erlang/process.{type Name}
import gleam/option
import gleam/result

/// A queue belongs to the process that created it.
pub type Queue(message)

/// A reservation remains charged after dequeue, until completion.
pub type Reservation

@external(erlang, "beryl_work_queue_ffi", "new")
fn new_queue(
  items: Int,
  bytes: Int,
  boundary: Boundary,
  telemetry: Bool,
  wake: fn() -> Nil,
) -> Queue(message)

/// Create a queue owned by the calling process.
pub fn new(
  limits: Limits,
  boundary: Boundary,
  telemetry: Bool,
  wake: fn() -> Nil,
) -> Queue(message) {
  new_queue(
    overload.max_items(limits),
    overload.max_bytes(limits),
    boundary,
    telemetry,
    wake,
  )
}

/// Publish a stable lookup name for an owner-scoped queue.
@external(erlang, "beryl_work_queue_ffi", "name")
pub fn name(queue: Queue(message), name: Name(message)) -> Nil

/// Resolve the current queue incarnation. A stopped owner has no queue.
@external(erlang, "beryl_work_queue_ffi", "lookup")
pub fn lookup(name: Name(message)) -> Result(Queue(message), AdmissionError)

/// Whether the current incarnation still admits work.
@external(erlang, "beryl_work_queue_ffi", "is_open")
pub fn is_open(queue: Queue(message)) -> Bool

/// Close once with a bounded admission failure as the terminal reason.
@external(erlang, "beryl_work_queue_ffi", "close_with_error")
pub fn close_with_error(queue: Queue(message), error: AdmissionError) -> Bool

/// Read the first recorded admission failure, if the close was due to overload.
@external(erlang, "beryl_work_queue_ffi", "close_reason")
pub fn close_reason(queue: Queue(message)) -> option.Option(AdmissionError)

/// Register an owned target for coalesced lifecycle requests.
@external(erlang, "beryl_work_queue_ffi", "register_target")
pub fn register_target(
  owner: Queue(message),
  key: String,
  target: Queue(message),
) -> Nil

/// Remove an owned target after its terminal transition.
@external(erlang, "beryl_work_queue_ffi", "remove_target")
pub fn remove_target(owner: Queue(message), key: String) -> Nil

/// Record one close intent. The target observes it on its wake or recovery tick.
@external(erlang, "beryl_work_queue_ffi", "close_target")
pub fn close_target(owner: Queue(message), key: String) -> Nil

/// Admit a request and wait on a one-shot reply alias. Late replies are dropped.
@external(erlang, "beryl_work_queue_ffi", "call")
pub fn call(
  queue: Queue(message),
  timeout_ms: Int,
  request: fn(fn(reply) -> Nil) -> message,
) -> Result(reply, overload.CallError)

/// Publish a pre-reserved request and wait on a one-shot reply alias.
@external(erlang, "beryl_work_queue_ffi", "call_reserved")
pub fn call_reserved(
  queue: Queue(message),
  reservation: Reservation,
  timeout_ms: Int,
  request: fn(fn(reply) -> Nil) -> message,
) -> Result(reply, overload.CallError)

/// Publish one item atomically, or return an error without publishing it.
@external(erlang, "beryl_work_queue_ffi", "publish")
pub fn publish(
  queue: Queue(message),
  message: message,
  bytes: Int,
) -> Result(Reservation, AdmissionError)

/// Publish with structural byte accounting. Closure environments are excluded.
@external(erlang, "beryl_work_queue_ffi", "publish_value")
pub fn publish_value(
  queue: Queue(message),
  message: message,
) -> Result(Reservation, AdmissionError)

/// Validate inspectable payload size without creating a reservation.
@external(erlang, "beryl_work_queue_ffi", "validate")
pub fn validate(
  value: value,
  max_bytes: Int,
  boundary: Boundary,
) -> Result(Nil, AdmissionError)

/// Admit work without exposing its reservation to the producer.
pub fn send(
  queue: Queue(message),
  message: message,
) -> Result(Nil, AdmissionError) {
  publish_value(queue, message) |> result.map(fn(_) { Nil })
}

/// Reserve an item held outside the pending queue, such as an unanswered ref.
@external(erlang, "beryl_work_queue_ffi", "retain")
pub fn retain(
  queue: Queue(message),
  value: value,
) -> Result(Reservation, AdmissionError)

/// Reserve output for already accepted work or teardown, even after input closes.
/// The same aggregate count and byte limits still apply.
@external(erlang, "beryl_work_queue_ffi", "retain_output")
pub fn retain_output(
  queue: Queue(message),
  value: value,
) -> Result(Reservation, AdmissionError)

/// Bind cleanup before a provisional resource becomes visible to its caller.
@external(erlang, "beryl_work_queue_ffi", "attach_cleanup")
pub fn attach_cleanup(
  queue: Queue(message),
  reservation: Reservation,
  cleanup: fn() -> Nil,
) -> Result(Nil, AdmissionError)

/// Reclaim unpublished reservations of dead producers from the owner's tick.
@external(erlang, "beryl_work_queue_ffi", "recover")
pub fn recover(queue: Queue(message)) -> Nil

/// Change an existing reservation's charge before publishing a callback result.
@external(erlang, "beryl_work_queue_ffi", "resize")
pub fn resize(
  queue: Queue(message),
  reservation: Reservation,
  value: value,
) -> Result(Nil, AdmissionError)

/// Atomically publish a retained result. Producer cleanup cannot reclaim it.
@external(erlang, "beryl_work_queue_ffi", "publish_reserved")
pub fn publish_reserved(
  queue: Queue(message),
  reservation: Reservation,
  message: message,
) -> Result(Reservation, AdmissionError)

/// Reclaim retained, unpublished work when its producing process exits.
@external(erlang, "beryl_work_queue_ffi", "release_producer")
pub fn release_producer(queue: Queue(message), producer: process.Pid) -> Nil

/// Admit work and reserve its owner's coalesced cleanup in the same operation.
@external(erlang, "beryl_work_queue_ffi", "publish_with_cleanup")
pub fn publish_with_cleanup(
  queue: Queue(message),
  key: String,
  message: message,
  cleanup: message,
) -> Result(Reservation, AdmissionError)

/// Schedule an existing cleanup obligation, even when data admission is full.
@external(erlang, "beryl_work_queue_ffi", "activate_cleanup")
pub fn activate_cleanup(
  queue: Queue(message),
  key: String,
) -> Result(Nil, AdmissionError)

/// Take the oldest item, retaining its reservation until `release`.
@external(erlang, "beryl_work_queue_ffi", "take")
pub fn take(queue: Queue(message)) -> Result(#(Reservation, message), Nil)

/// Take the first eligible item without changing the order of other items.
@external(erlang, "beryl_work_queue_ffi", "take_matching")
pub fn take_matching(
  queue: Queue(message),
  eligible: fn(message) -> Bool,
) -> Result(#(Reservation, message), Nil)

/// Complete or cancel a reservation. Repeated releases are harmless.
@external(erlang, "beryl_work_queue_ffi", "release")
pub fn release(queue: Queue(message), reservation: Reservation) -> Nil

/// Stop admitting work. Existing reservations remain available to drain.
@external(erlang, "beryl_work_queue_ffi", "close")
pub fn close(queue: Queue(message)) -> Nil

/// Close admission once. Only the first caller must initiate teardown.
@external(erlang, "beryl_work_queue_ffi", "close_once")
pub fn close_once(queue: Queue(message)) -> Bool

/// Read occupancy and oldest outstanding age without asking the owner.
@external(erlang, "beryl_work_queue_ffi", "snapshot")
pub fn snapshot(queue: Queue(message)) -> Result(Occupancy, AdmissionError)
