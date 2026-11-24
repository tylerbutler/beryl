//// Experimental data queue. Target-registry controls are not implemented.
//// The ETS row contains this typed ledger directly, without map conversion.
//// Owners still need a recovery tick if a publisher dies before its wake.

import beryl/overload
import beryl/telemetry
import beryl/work_queue
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import rasa/monotonic

type Table(state)

type CleanupKey

/// Reservation identity is a native reference, not a reconstructed wire value.
pub type Reservation =
  reference.Reference

type Lease(message) {
  Pending(bytes: Int, at: Int, message: message, cleanup: Option(fn() -> Nil))
  Running(bytes: Int, at: Int)
  Retained(
    bytes: Int,
    at: Int,
    producer: process.Pid,
    cleanup: Option(fn() -> Nil),
  )
  DormantCleanup(bytes: Int, at: Int, message: message)
}

type State(message) {
  State(
    open: Bool,
    close_reason: Option(overload.AdmissionError),
    version: Int,
    items: Int,
    bytes: Int,
    high_items: Int,
    high_bytes: Int,
    rejected: Int,
    cancelled: Int,
    front: List(Reservation),
    back: List(Reservation),
    leases: Dict(Reservation, Lease(message)),
    cleanup_keys: Dict(CleanupKey, Reservation),
    notified: Bool,
  )
}

/// A process owns the ETS ledger and drains its own typed messages.
pub opaque type Queue(message) {
  Queue(
    table: Table(State(message)),
    owner: process.Pid,
    limits: overload.Limits,
    boundary: overload.Boundary,
    telemetry: Bool,
    wake: fn() -> Nil,
  )
}

type Change(message, value) {
  Keep(value: value)
  Commit(
    state: State(message),
    value: value,
    effects: List(fn() -> Nil),
    outcome: telemetry.QueueOutcome,
  )
}

@external(erlang, "beryl_typed_queue_spike_ffi", "new")
fn new_table(state: state) -> Table(state)

@external(erlang, "beryl_typed_queue_spike_ffi", "read")
fn read(table: Table(state)) -> Result(state, overload.AdmissionError)

@external(erlang, "beryl_typed_queue_spike_ffi", "compare_replace")
fn compare_replace(
  table: Table(state),
  before: state,
  after: state,
) -> Result(Bool, overload.AdmissionError)

@external(erlang, "beryl_typed_queue_spike_ffi", "assert_owner")
fn assert_owner(owner: process.Pid) -> Nil

@external(erlang, "beryl_typed_queue_spike_ffi", "key")
fn cleanup_key(value: value) -> CleanupKey

@external(erlang, "beryl_typed_queue_spike_ffi", "structural_bytes")
fn structural_bytes(value: value, limit: Int) -> Int

@external(erlang, "beryl_typed_queue_spike_ffi", "table_words")
fn table_words(table: Table(state)) -> Int

@external(erlang, "beryl_typed_queue_spike_ffi", "bounded_call")
fn bounded_call(
  owner: process.Pid,
  timeout_ms: Int,
  request: fn(fn(reply) -> Nil) -> message,
  publish: fn(message) -> Result(Reservation, overload.AdmissionError),
  cancel: fn(Reservation) -> Nil,
) -> Result(reply, overload.CallError)

fn now() -> Int {
  monotonic.time(monotonic.Millisecond)
}

/// Create the typed data ledger in an owner-scoped ETS table.
pub fn new(
  limits: overload.Limits,
  boundary: overload.Boundary,
  telemetry: Bool,
  wake: fn() -> Nil,
) -> Queue(message) {
  let state =
    State(
      True,
      None,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      [],
      [],
      dict.new(),
      dict.new(),
      False,
    )
  Queue(new_table(state), process.self(), limits, boundary, telemetry, wake)
}

// nolint: unused_exports -- called by the generated actor fixture
/// Publish a lookup name owned by the queue owner.
@external(erlang, "beryl_typed_queue_spike_ffi", "name")
pub fn name(queue: Queue(message), name: process.Name(message)) -> Nil

/// Resolve the named queue without a new actor hop.
@external(erlang, "beryl_typed_queue_spike_ffi", "lookup")
pub fn lookup(
  name: process.Name(message),
) -> Result(Queue(message), overload.AdmissionError)

fn emit(
  queue: Queue(message),
  state: State(message),
  outcome: telemetry.QueueOutcome,
) -> Nil {
  use <- bool.guard(when: !queue.telemetry, return: Nil)
  telemetry.emit(
    True,
    telemetry.QueueOccupancy(occupancy(queue, state), outcome),
  )
}

fn transact(
  queue: Queue(message),
  change: fn(State(message)) -> Change(message, value),
) -> Result(value, overload.AdmissionError) {
  use before <- result.try(read(queue.table))
  case change(before) {
    Keep(value) -> {
      emit(queue, before, telemetry.QueueChanged)
      Ok(value)
    }
    Commit(changed, value, effects, outcome) -> {
      let after = State(..changed, version: before.version + 1)
      use committed <- result.try(compare_replace(queue.table, before, after))
      use <- bool.lazy_guard(when: !committed, return: fn() {
        transact(queue, change)
      })
      list.each(effects, fn(effect) { effect() })
      emit(queue, after, outcome)
      Ok(value)
    }
  }
}

fn rejection(
  state: State(message),
  error: overload.AdmissionError,
) -> Change(message, Result(value, overload.AdmissionError)) {
  Commit(
    State(..state, rejected: state.rejected + 1),
    Error(error),
    [],
    telemetry.QueueRejected,
  )
}

fn charge(
  queue: Queue(message),
  state: State(message),
  items: Int,
  bytes: Int,
) -> Result(State(message), overload.AdmissionError) {
  use <- bool.guard(
    when: items > overload.max_items(queue.limits)
      || bytes > overload.max_bytes(queue.limits),
    return: Error(overload.Overloaded(queue.boundary)),
  )
  Ok(
    State(
      ..state,
      items: items,
      bytes: bytes,
      high_items: int.max(items, state.high_items),
      high_bytes: int.max(bytes, state.high_bytes),
    ),
  )
}

fn publication(
  queue: Queue(message),
  state: State(message),
  id: Reservation,
  lease: Lease(message),
) -> #(State(message), List(fn() -> Nil)) {
  let effects = case state.notified {
    True -> []
    False -> [queue.wake]
  }
  #(
    State(
      ..state,
      leases: dict.insert(state.leases, id, lease),
      back: [id, ..state.back],
      notified: True,
    ),
    effects,
  )
}

fn published(
  queue: Queue(message),
  state: State(message),
  id: Reservation,
  lease: Lease(message),
) -> Change(message, Result(Reservation, overload.AdmissionError)) {
  let #(next, effects) = publication(queue, state, id, lease)
  Commit(next, Ok(id), effects, telemetry.QueueChanged)
}

/// Admit and publish data in one compare-and-replace.
pub fn publish(
  queue: Queue(message),
  message: message,
  bytes: Int,
) -> Result(Reservation, overload.AdmissionError) {
  case bytes < 0 {
    // nolint: avoid_panic -- preserves the native invalid-charge precondition
    True -> panic as "invalid declared byte charge"
    False -> Nil
  }
  let id = reference.new()
  let at = now()
  transact(queue, fn(state) {
    case bytes > overload.max_bytes(queue.limits), state.open {
      True, _ -> rejection(state, overload.ItemTooLarge(queue.boundary))
      False, False -> rejection(state, overload.Closed)
      False, True ->
        case charge(queue, state, state.items + 1, state.bytes + bytes) {
          Error(error) -> rejection(state, error)
          Ok(next) ->
            published(queue, next, id, Pending(bytes, at, message, None))
        }
    }
  })
  |> result.flatten
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Apply the same structural accounting as the native queue.
pub fn publish_value(
  queue: Queue(message),
  message: message,
) -> Result(Reservation, overload.AdmissionError) {
  publish(
    queue,
    message,
    structural_bytes(message, overload.max_bytes(queue.limits)),
  )
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Send without exposing a reservation to the producer.
pub fn send(
  queue: Queue(message),
  message: message,
) -> Result(Nil, overload.AdmissionError) {
  publish_value(queue, message) |> result.replace(Nil)
}

// nolint: unused_exports -- retained for the original queue interface
/// Check structural bytes without touching the ledger.
pub fn validate(
  value: value,
  max_bytes: Int,
  boundary: overload.Boundary,
) -> Result(Nil, overload.AdmissionError) {
  use <- bool.guard(
    when: structural_bytes(value, max_bytes) > max_bytes,
    return: Error(overload.ItemTooLarge(boundary)),
  )
  Ok(Nil)
}

fn retained(
  queue: Queue(message),
  value: value,
  completing: Bool,
) -> Result(Reservation, overload.AdmissionError) {
  let bytes = structural_bytes(value, overload.max_bytes(queue.limits))
  let id = reference.new()
  let at = now()
  let producer = process.self()
  transact(queue, fn(state) {
    case state.open || completing, bytes <= overload.max_bytes(queue.limits) {
      False, _ -> rejection(state, overload.Closed)
      True, False -> rejection(state, overload.ItemTooLarge(queue.boundary))
      True, True ->
        case charge(queue, state, state.items + 1, state.bytes + bytes) {
          Error(error) -> rejection(state, error)
          Ok(next) ->
            Commit(
              State(
                ..next,
                leases: dict.insert(
                  next.leases,
                  id,
                  Retained(bytes, at, producer, None),
                ),
              ),
              Ok(id),
              [],
              telemetry.QueueChanged,
            )
        }
    }
  })
  |> result.flatten
}

/// Retain unpublished capacity owned by the current producer.
pub fn retain(
  queue: Queue(message),
  value: value,
) -> Result(Reservation, overload.AdmissionError) {
  retained(queue, value, False)
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Retain completion capacity after ingress closes, within aggregate limits.
pub fn retain_output(
  queue: Queue(message),
  value: value,
) -> Result(Reservation, overload.AdmissionError) {
  retained(queue, value, True)
}

/// Attach a callback only to a retained, unpublished reservation.
pub fn attach_cleanup(
  queue: Queue(message),
  id: Reservation,
  cleanup: fn() -> Nil,
) -> Result(Nil, overload.AdmissionError) {
  transact(queue, fn(state) {
    case dict.get(state.leases, id) {
      Ok(Retained(bytes, at, producer, None)) ->
        Commit(
          State(
            ..state,
            leases: dict.insert(
              state.leases,
              id,
              Retained(bytes, at, producer, Some(cleanup)),
            ),
          ),
          Ok(Nil),
          [],
          telemetry.QueueChanged,
        )
      Ok(Retained(_, _, _, Some(_)))
      | Ok(Pending(_, _, _, _))
      | Ok(Running(_, _))
      | Ok(DormantCleanup(_, _, _))
      | Error(Nil) -> rejection(state, overload.Closed)
    }
  })
  |> result.flatten
}

fn with_bytes(lease: Lease(message), bytes: Int) -> Lease(message) {
  case lease {
    Pending(_, at, message, cleanup) -> Pending(bytes, at, message, cleanup)
    Running(_, at) -> Running(bytes, at)
    Retained(_, at, producer, cleanup) -> Retained(bytes, at, producer, cleanup)
    DormantCleanup(_, at, message) -> DormantCleanup(bytes, at, message)
  }
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Resize any existing charge without changing its lifecycle.
pub fn resize(
  queue: Queue(message),
  id: Reservation,
  value: value,
) -> Result(Nil, overload.AdmissionError) {
  let bytes = structural_bytes(value, overload.max_bytes(queue.limits))
  transact(queue, fn(state) {
    case dict.get(state.leases, id) {
      Error(Nil) -> rejection(state, overload.Closed)
      Ok(lease) ->
        case bytes > overload.max_bytes(queue.limits) {
          True -> rejection(state, overload.ItemTooLarge(queue.boundary))
          False ->
            case
              charge(
                queue,
                state,
                state.items,
                state.bytes - lease.bytes + bytes,
              )
            {
              Error(error) -> rejection(state, error)
              Ok(next) ->
                Commit(
                  State(
                    ..next,
                    leases: dict.insert(
                      next.leases,
                      id,
                      with_bytes(lease, bytes),
                    ),
                  ),
                  Ok(Nil),
                  [],
                  telemetry.QueueChanged,
                )
            }
        }
    }
  })
  |> result.flatten
}

/// Publish retained output, transferring it out of producer reclamation.
pub fn publish_reserved(
  queue: Queue(message),
  id: Reservation,
  message: message,
) -> Result(Reservation, overload.AdmissionError) {
  let bytes = structural_bytes(message, overload.max_bytes(queue.limits))
  transact(queue, fn(state) {
    case dict.get(state.leases, id) {
      Ok(Retained(before, at, _, cleanup)) ->
        case bytes > overload.max_bytes(queue.limits) {
          True -> rejection(state, overload.ItemTooLarge(queue.boundary))
          False ->
            case
              charge(queue, state, state.items, state.bytes - before + bytes)
            {
              Error(error) -> rejection(state, error)
              Ok(next) ->
                published(queue, next, id, Pending(bytes, at, message, cleanup))
            }
        }
      Ok(Pending(_, _, _, _))
      | Ok(Running(_, _))
      | Ok(DormantCleanup(_, _, _))
      | Error(Nil) -> rejection(state, overload.Closed)
    }
  })
  |> result.flatten
}

/// Reserve the first keyed cleanup together with its owner's admitted mutation.
pub fn publish_with_cleanup(
  queue: Queue(message),
  key: key,
  message: message,
  cleanup: message,
) -> Result(Reservation, overload.AdmissionError) {
  let key = cleanup_key(key)
  let bytes = structural_bytes(message, overload.max_bytes(queue.limits))
  let cleanup_bytes =
    structural_bytes(cleanup, overload.max_bytes(queue.limits))
  let id = reference.new()
  let cleanup_id = reference.new()
  let at = now()
  transact(queue, fn(state) {
    let #(extra_items, extra_bytes, next, closing) = case
      dict.get(state.cleanup_keys, key)
    {
      Error(Nil) -> #(
        1,
        cleanup_bytes,
        State(
          ..state,
          cleanup_keys: dict.insert(state.cleanup_keys, key, cleanup_id),
          leases: dict.insert(
            state.leases,
            cleanup_id,
            DormantCleanup(cleanup_bytes, at, cleanup),
          ),
        ),
        False,
      )
      Ok(existing) ->
        case dict.get(state.leases, existing) {
          Ok(DormantCleanup(_, _, _)) -> #(0, 0, state, False)
          Ok(Pending(_, _, _, _))
          | Ok(Running(_, _))
          | Ok(Retained(_, _, _, _)) -> #(0, 0, state, True)
          // nolint: avoid_panic -- a missing lease violates the private ledger invariant
          Error(Nil) -> panic as "queue cleanup key lost its reservation"
        }
    }
    case
      state.open && !closing,
      bytes + extra_bytes <= overload.max_bytes(queue.limits)
    {
      False, _ -> rejection(state, overload.Closed)
      True, False -> rejection(state, overload.ItemTooLarge(queue.boundary))
      True, True ->
        case
          charge(
            queue,
            next,
            state.items + 1 + extra_items,
            state.bytes + bytes + extra_bytes,
          )
        {
          Error(error) -> rejection(state, error)
          Ok(charged) ->
            published(queue, charged, id, Pending(bytes, at, message, None))
        }
    }
  })
  |> result.flatten
}

/// Activate a dormant cleanup without admitting any new charge.
pub fn activate_cleanup(
  queue: Queue(message),
  key: key,
) -> Result(Nil, overload.AdmissionError) {
  let key = cleanup_key(key)
  transact(queue, fn(state) {
    case dict.get(state.cleanup_keys, key) {
      Error(Nil) -> Keep(Ok(Nil))
      Ok(id) ->
        case dict.get(state.leases, id) {
          Ok(DormantCleanup(bytes, _, message)) -> {
            let at = now()
            let #(next, effects) =
              publication(queue, state, id, Pending(bytes, at, message, None))
            Commit(next, Ok(Nil), effects, telemetry.QueueChanged)
          }
          Ok(Pending(_, _, _, _))
          | Ok(Running(_, _))
          | Ok(Retained(_, _, _, _)) -> Keep(Ok(Nil))
          // nolint: avoid_panic -- a missing lease violates the private ledger invariant
          Error(Nil) -> panic as "queue cleanup key lost its reservation"
        }
    }
  })
  |> result.flatten
}

fn ordered(state: State(message)) -> List(Reservation) {
  list.append(state.front, list.reverse(state.back))
}

fn taken(
  state: State(message),
  id: Reservation,
  front: List(Reservation),
  back: List(Reservation),
) -> Change(message, Result(#(Reservation, message), error)) {
  case dict.get(state.leases, id) {
    Ok(Pending(bytes, at, message, _)) ->
      Commit(
        State(
          ..state,
          front: front,
          back: back,
          leases: dict.insert(state.leases, id, Running(bytes, at)),
        ),
        Ok(#(id, message)),
        [],
        telemetry.QueueChanged,
      )
    Ok(Running(_, _))
    | Ok(Retained(_, _, _, _))
    | Ok(DormantCleanup(_, _, _))
    | Error(Nil) -> {
      // nolint: avoid_panic -- native dequeue also rejects a corrupt private ledger
      panic as "queue pending entry is not pending"
    }
  }
}

fn owner_result(outcome: Result(value, overload.AdmissionError)) -> value {
  case outcome {
    Ok(value) -> value
    Error(error) -> {
      let description =
        "queue owner lost its ETS table: " <> overload.describe(error)
      // nolint: avoid_panic -- a live owner cannot lose its private table
      panic as description
    }
  }
}

/// Dequeue in owner order without releasing the running reservation.
pub fn take(
  queue: Queue(message),
) -> Result(#(Reservation, message), work_queue.TakeError) {
  assert_owner(queue.owner)
  transact(queue, fn(state) {
    case state.front {
      [id, ..rest] -> taken(state, id, rest, state.back)
      [] ->
        case list.reverse(state.back) {
          [id, ..rest] -> taken(state, id, rest, [])
          [] ->
            Commit(
              State(..state, notified: False),
              Error(work_queue.Empty),
              [],
              telemetry.QueueChanged,
            )
        }
    }
  })
  |> owner_result
}

fn eligible(
  pending: List(Reservation),
  leases: Dict(Reservation, Lease(message)),
  check: fn(message) -> Bool,
) -> Result(Reservation, Nil) {
  case pending {
    [] -> Error(Nil)
    [id, ..rest] ->
      case dict.get(leases, id) {
        Ok(Pending(_, _, message, _)) ->
          case check(message) {
            True -> Ok(id)
            False -> eligible(rest, leases, check)
          }
        Ok(Running(_, _))
        | Ok(Retained(_, _, _, _))
        | Ok(DormantCleanup(_, _, _))
        | Error(Nil) -> {
          // nolint: avoid_panic -- native dequeue also rejects a corrupt private ledger
          panic as "queue pending entry is not pending"
        }
      }
  }
}

/// Dequeue the first eligible message, preserving the others' order.
/// The predicate is speculative and can run again after a failed CAS.
pub fn take_matching(
  queue: Queue(message),
  check: fn(message) -> Bool,
) -> Result(#(Reservation, message), Nil) {
  assert_owner(queue.owner)
  transact(queue, fn(state) {
    case eligible(ordered(state), state.leases, check) {
      Error(Nil) ->
        Commit(
          State(..state, notified: False),
          Error(Nil),
          [],
          telemetry.QueueChanged,
        )
      Ok(id) ->
        taken(
          state,
          id,
          list.filter(state.front, fn(other) { other != id }),
          list.filter(state.back, fn(other) { other != id }),
        )
    }
  })
  |> owner_result
}

fn effects(cleanup: Option(fn() -> Nil)) -> List(fn() -> Nil) {
  case cleanup {
    None -> []
    Some(cleanup) -> [cleanup]
  }
}

fn removed(
  state: State(message),
  id: Reservation,
  lease: Lease(message),
  cancelled: Int,
  callbacks: List(fn() -> Nil),
) -> Change(message, Nil) {
  Commit(
    State(
      ..state,
      items: state.items - 1,
      bytes: state.bytes - lease.bytes,
      cancelled: state.cancelled + cancelled,
      front: list.filter(state.front, fn(other) { other != id }),
      back: list.filter(state.back, fn(other) { other != id }),
      leases: dict.delete(state.leases, id),
      cleanup_keys: state.cleanup_keys
        |> dict.filter(fn(_, value) { value != id }),
    ),
    Nil,
    callbacks,
    telemetry.QueueChanged,
  )
}

fn unavailable_or(
  outcome: Result(value, overload.AdmissionError),
  missing: value,
) -> value {
  case outcome {
    Ok(value) -> value
    Error(overload.Unavailable) -> missing
    Error(error) -> {
      let description = "unexpected table error: " <> overload.describe(error)
      // nolint: avoid_panic -- the native table primitive can only return Unavailable
      panic as description
    }
  }
}

/// Release running work or cancel pending/retained work exactly once.
pub fn release(queue: Queue(message), id: Reservation) -> Nil {
  transact(queue, fn(state) {
    case dict.get(state.leases, id) {
      Error(Nil) -> Keep(Nil)
      Ok(lease) ->
        case lease {
          Pending(_, _, _, cleanup) ->
            removed(state, id, lease, 1, effects(cleanup))
          Retained(_, _, _, cleanup) ->
            removed(state, id, lease, 0, effects(cleanup))
          Running(_, _) | DormantCleanup(_, _, _) ->
            removed(state, id, lease, 0, [])
        }
    }
  })
  |> unavailable_or(Nil)
}

/// Timeout cancellation removes pending work only, never running work.
pub fn cancel_pending(queue: Queue(message), id: Reservation) -> Nil {
  transact(queue, fn(state) {
    case dict.get(state.leases, id) {
      Ok(lease) ->
        case lease {
          Pending(_, _, _, cleanup) ->
            removed(state, id, lease, 1, effects(cleanup))
          Running(_, _) | Retained(_, _, _, _) | DormantCleanup(_, _, _) ->
            Keep(Nil)
        }
      Error(Nil) -> Keep(Nil)
    }
  })
  |> unavailable_or(Nil)
}

fn reclaim(
  queue: Queue(message),
  should_release: fn(process.Pid) -> Bool,
) -> Nil {
  transact(queue, fn(state) {
    let #(next, callbacks, count) =
      dict.fold(state.leases, #(state, [], 0), fn(acc, id, lease) {
        let #(current, callbacks, count) = acc
        case lease {
          Pending(_, _, _, _) | Running(_, _) | DormantCleanup(_, _, _) -> acc
          Retained(_, _, producer, cleanup) ->
            case should_release(producer) {
              False -> acc
              True -> #(
                State(
                  ..current,
                  items: current.items - 1,
                  bytes: current.bytes - lease.bytes,
                  leases: dict.delete(current.leases, id),
                ),
                list.append(effects(cleanup), callbacks),
                count + 1,
              )
            }
        }
      })
    case count {
      0 -> Keep(Nil)
      _ ->
        Commit(
          State(..next, cancelled: next.cancelled + count),
          Nil,
          callbacks,
          telemetry.QueueChanged,
        )
    }
  })
  |> unavailable_or(Nil)
}

/// Reclaim only unpublished reservations belonging to the given producer.
pub fn release_producer(queue: Queue(message), producer: process.Pid) -> Nil {
  reclaim(queue, fn(owner) { owner == producer })
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Reclaim dead producers from the owner's recovery tick.
pub fn recover(queue: Queue(message)) -> Nil {
  assert_owner(queue.owner)
  reclaim(queue, fn(producer) { !process.is_alive(producer) })
}

/// Close ingress without dropping accepted work.
pub fn close(queue: Queue(message)) -> Nil {
  transact(queue, fn(state) {
    Commit(State(..state, open: False), Nil, [], telemetry.QueueChanged)
  })
  |> unavailable_or(Nil)
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Whether the queue still accepts fresh input.
pub fn is_open(queue: Queue(message)) -> Bool {
  read(queue.table)
  |> result.map(fn(state) { state.open })
  |> unavailable_or(False)
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Record the same first-error and normal-drain policy as the native queue.
pub fn close_with_error(
  queue: Queue(message),
  error: overload.AdmissionError,
) -> Bool {
  let outcome =
    transact(queue, fn(state) {
      case state.open, state.close_reason, error {
        False, None, overload.Closed -> Keep(False)
        _, Some(_), _ -> Keep(False)
        _, None, _ ->
          Commit(
            State(..state, open: False, close_reason: Some(error)),
            True,
            [],
            telemetry.QueueChanged,
          )
      }
    })
  unavailable_or(outcome, False)
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Missing queues and normal closure have no admission-failure reason.
pub fn close_reason(queue: Queue(message)) -> Option(overload.AdmissionError) {
  read(queue.table)
  |> result.map(fn(state) { state.close_reason })
  |> unavailable_or(None)
}

fn occupancy(
  queue: Queue(message),
  state: State(message),
) -> overload.Occupancy {
  let at = now()
  let oldest =
    dict.fold(state.leases, at, fn(oldest, _, lease) {
      case lease {
        DormantCleanup(_, _, _) -> oldest
        Pending(_, _, _, _) | Running(_, _) | Retained(_, _, _, _) ->
          int.min(oldest, lease.at)
      }
    })
  overload.Occupancy(
    queue.boundary,
    state.items,
    state.bytes,
    overload.max_items(queue.limits),
    overload.max_bytes(queue.limits),
    state.high_items,
    state.high_bytes,
    state.rejected,
    state.cancelled,
    int.max(0, at - oldest),
  )
}

/// Read counters from the typed ledger without asking its actor.
pub fn snapshot(
  queue: Queue(message),
) -> Result(overload.Occupancy, overload.AdmissionError) {
  read(queue.table) |> result.map(occupancy(queue, _))
}

/// Test-only stored ETS words; this is not RSS or per-update allocation.
pub fn debug_storage_words(queue: Queue(message)) -> Int {
  table_words(queue.table)
}

/// Use native one-shot alias/monitor primitives with typed publication/cancellation.
pub fn call(
  queue: Queue(message),
  timeout_ms: Int,
  request: fn(fn(reply) -> Nil) -> message,
) -> Result(reply, overload.CallError) {
  bounded_call(
    queue.owner,
    timeout_ms,
    request,
    publish_value(queue, _),
    cancel_pending(queue, _),
  )
}

// nolint: unused_exports -- retained for the original queue interface
/// Publish reserved output through the same one-shot call boundary.
pub fn call_reserved(
  queue: Queue(message),
  reservation: Reservation,
  timeout_ms: Int,
  request: fn(fn(reply) -> Nil) -> message,
) -> Result(reply, overload.CallError) {
  bounded_call(
    queue.owner,
    timeout_ms,
    request,
    publish_reserved(queue, reservation, _),
    cancel_pending(queue, _),
  )
}

// nolint: unused_exports -- called by the generated contract fixtures
/// Timeout keeps keyed-cleanup work discoverable until its owner drains it.
pub fn call_with_cleanup(
  queue: Queue(message),
  key: key,
  timeout_ms: Int,
  request: fn(fn(reply) -> Nil) -> message,
  cleanup: message,
) -> Result(reply, overload.CallError) {
  bounded_call(
    queue.owner,
    timeout_ms,
    request,
    publish_with_cleanup(queue, key, _, cleanup),
    fn(_) { Nil },
  )
}
