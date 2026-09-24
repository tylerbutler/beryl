//// Shared connection admission controls for transports.
////
//// Enforces three independent dimensions in a single serialized actor:
////
//// - a per-IP ceiling (`max_per_ip`), which throttles a single peer, and
//// - a per-system total ceiling (`max_total`) on one node, which caps
////   concurrent connections across every IP so distributed/rotating source
////   addresses cannot exhaust that system's process, socket, and runtime
////   budget, and
//// - a per-IP token bucket, which prevents reconnect churn from repeatedly
////   refreshing per-connection frame and message bursts.
////
//// All three are checked atomically inside `handle_message` on acquire, so
//// concurrent opens cannot race past either ceiling. A single `Permit` tracks
//// concurrency dimensions and the same process monitor reclaims both when the
//// holder dies without releasing. Counts and rate buckets are checkpointed
//// to an ETS table with an heir, so a replacement limiter worker can recover
//// live holders and per-IP rate history. Disconnects release concurrency
//// capacity without resetting the IP's rate bucket. Idle rate buckets expire
//// once their allowance has fully refilled.
////
//// The heir stops with the enclosing beryl supervisor. This state survives
//// router and limiter-worker restarts, but not shutdown or replacement of
//// that supervisor, or a node restart.

import beryl/log
import beryl/overload
import beryl/rate_limit
import beryl/work_queue
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import heirloom
import rasa/atomic
import rasa/monotonic

const registry_call_timeout_ms = 100

const bucket_sweep_interval_ms = 60_000

const queue_recovery_interval_ms = 100

const one_second_ns = 1_000_000_000

fn monotonic_time_ns() -> Int {
  monotonic.time(monotonic.Nanosecond)
}

type ReservationToken =
  atomic.Atomic

const pending_token = 0

const accepted_token = 1

const cancelled_token = 2

fn new_reservation_token() -> ReservationToken {
  atomic.new()
}

fn cancel_reservation_token(token: ReservationToken) -> Bool {
  atomic.exchange(token, cancelled_token) != cancelled_token
}

fn reservation_token_active(token: ReservationToken) -> Bool {
  atomic.get(token) != cancelled_token
}

/// Opaque connection limiter registry.
pub opaque type ConnectionLimiter {
  ConnectionLimiter(subject: Subject(Message), name: process.Name(Message))
}

/// A checked-out connection slot. Release it when the socket closes.
pub opaque type Permit {
  Permit(
    limiter: ConnectionLimiter,
    reservation: reference.Reference,
    token: ReservationToken,
  )
}

type RateBucket {
  RateBucket(bucket: rate_limit.Bucket, last_seen_ns: Int)
}

type Reservation {
  Reservation(ip: String, owner: Pid, monitor: Monitor, token: ReservationToken)
}

type CheckpointTable =
  heirloom.Table(String, State)

type CheckpointRegistryKey

type CheckpointMessage {
  CheckpointAnnounced(CheckpointTable)
  CheckpointTransferred(
    Result(
      heirloom.Transfer(String, State, decode.Dynamic),
      heirloom.TransferDecodeError,
    ),
  )
  CheckpointSupervisorDown(process.Down)
}

type CheckpointState {
  CheckpointState(key: CheckpointRegistryKey, table: Option(CheckpointTable))
}

@internal
pub opaque type CheckpointHeir {
  CheckpointHeir(
    pid: Pid,
    subject: Subject(CheckpointMessage),
    key: CheckpointRegistryKey,
  )
}

type State {
  State(
    store_key: process.Name(Message),
    inbox: work_queue.Queue(Message),
    draining: Bool,
    checkpoint: Option(CheckpointTable),
    /// Per-IP ceiling; 0 disables the per-IP check.
    max_per_ip: Int,
    /// Per-system ceiling across all IPs; 0 disables the total check.
    max_total: Int,
    /// Per-IP connection-attempt rate limit; `None` disables it.
    connection_rate: Option(rate_limit.RateLimitConfig),
    /// Idle buckets can be dropped without refreshing their allowance after
    /// this duration because they have naturally refilled to capacity.
    bucket_ttl_ns: Int,
    /// Live connection count across every IP, checked against `max_total`.
    total: Int,
    counts: Dict(String, Int),
    rate_buckets: Dict(String, RateBucket),
    /// Every acquired reservation has an owner and monitor. The unique
    /// reservation identity keeps release, cancellation, and transfer
    /// idempotent when their messages race.
    reservations: Dict(reference.Reference, Reservation),
    monitors: Dict(Monitor, reference.Reference),
  )
}

pub opaque type Message {
  Acquire(
    reservation: reference.Reference,
    ip: String,
    limiter: ConnectionLimiter,
    owner: Pid,
    token: ReservationToken,
    reply: fn(Result(Permit, Nil)) -> Nil,
  )
  Bind(
    reservation: reference.Reference,
    owner: Pid,
    reply: fn(Result(Nil, Nil)) -> Nil,
  )
  Complete(reservation: reference.Reference, token: ReservationToken)
  Drain(subject: Subject(Message))
  RecoverQueue(subject: Subject(Message))
  Release(reservation: reference.Reference)
  HolderDown(down: process.Down)
  Sweep(subject: Subject(Message))
  Stop(reply: Subject(Nil))
}

@external(erlang, "beryl_ffi", "connection_limit_checkpoint_supervisor")
fn checkpoint_supervisor() -> Pid

@external(erlang, "beryl_ffi", "connection_limit_checkpoint_registry_key")
fn checkpoint_registry_key(
  supervisor: Pid,
  store_key: process.Name(message),
) -> CheckpointRegistryKey

@external(erlang, "beryl_ffi", "connection_limit_checkpoint_registry_get")
fn checkpoint_registry_get(
  key: CheckpointRegistryKey,
) -> Option(heirloom.Table(table_key, value))

@external(erlang, "beryl_ffi", "connection_limit_checkpoint_registry_put")
fn checkpoint_registry_put(
  key: CheckpointRegistryKey,
  table: heirloom.Table(table_key, value),
) -> Nil

@external(erlang, "beryl_ffi", "connection_limit_checkpoint_registry_compare_erase")
fn checkpoint_registry_compare_erase(
  key: CheckpointRegistryKey,
  table: heirloom.Table(table_key, value),
) -> Nil

fn persist(state: State) -> State {
  let assert Some(table) = state.checkpoint
  let assert Ok(Nil) = heirloom.insert(table, "state", state)
  state
}

fn open_state(store_key: process.Name(Message), initial: State) -> State {
  let supervisor = checkpoint_supervisor()
  let key = checkpoint_registry_key(supervisor, store_key)
  case checkpoint_registry_get(key) {
    Some(table) ->
      case heirloom.exists(table) {
        True -> {
          let assert Ok(Some(state)) = heirloom.lookup(table, "state")
          State(..state, checkpoint: Some(table))
        }
        False -> new_state_checkpoint(supervisor, key, initial)
      }
    None -> new_state_checkpoint(supervisor, key, initial)
  }
}

fn new_state_checkpoint(
  supervisor: Pid,
  key: CheckpointRegistryKey,
  initial: State,
) -> State {
  let assert Ok(checkpoint_heir) = start_checkpoint_heir(supervisor, key)
  let specification =
    heirloom.spec("beryl_connection_limit_state", heirloom.Set)
    |> heirloom.with_access(heirloom.Public)
    |> heirloom.with_heir(checkpoint_heir.pid, initial.store_key)
  let assert Ok(table): Result(CheckpointTable, _) =
    heirloom.create(specification)
  let state = State(..initial, checkpoint: Some(table))
  let assert Ok(Nil) = heirloom.insert(table, "state", state)
  checkpoint_registry_put(key, table)
  process.send(checkpoint_heir.subject, CheckpointAnnounced(table))
  state
}

fn handle_checkpoint_message(
  state: CheckpointState,
  message: CheckpointMessage,
) -> actor.Next(CheckpointState, CheckpointMessage) {
  case message {
    CheckpointAnnounced(table) ->
      actor.continue(CheckpointState(..state, table: Some(table)))
    CheckpointTransferred(Ok(heirloom.Transfer(table:, ..))) ->
      actor.continue(CheckpointState(..state, table: Some(table)))
    CheckpointTransferred(Error(_error)) -> {
      log.warn(
        log.new("beryl.connection_limit"),
        "Invalid ETS transfer ignored",
        [],
      )
      actor.continue(state)
    }
    CheckpointSupervisorDown(_) -> {
      cleanup_checkpoint(state)
      actor.stop()
    }
  }
}

fn cleanup_checkpoint(state: CheckpointState) -> Nil {
  let self = process.self()
  case state.table {
    Some(table) -> checkpoint_registry_compare_erase(state.key, table)
    None ->
      case checkpoint_registry_get(state.key) {
        Some(table) ->
          case heirloom.heir(table) {
            Ok(Some(pid)) if pid == self ->
              checkpoint_registry_compare_erase(state.key, table)
            Ok(Some(_)) | Ok(None) -> Nil
            Error(heirloom.TableDoesNotExist) -> Nil
            Error(heirloom.AccessDenied) -> Nil
          }
        None -> Nil
      }
  }
}

fn start_checkpoint_heir(
  supervisor: Pid,
  key: CheckpointRegistryKey,
) -> Result(CheckpointHeir, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let monitor = process.monitor(supervisor)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_specific_monitor(monitor, CheckpointSupervisorDown)
      |> heirloom.select_transfers(decode.dynamic, CheckpointTransferred)
    actor.initialised(CheckpointState(key: key, table: None))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_checkpoint_message)
  |> actor.start
  |> result.map(fn(started) {
    process.unlink(started.pid)
    CheckpointHeir(pid: started.pid, subject: started.data, key: key)
  })
}

@internal
pub fn start_checkpoint_heir_for_test(
  supervisor: Pid,
  store_key: process.Name(message),
) -> Result(CheckpointHeir, actor.StartError) {
  start_checkpoint_heir(
    supervisor,
    checkpoint_registry_key(supervisor, store_key),
  )
}

@internal
pub fn checkpoint_heir_pid(heir: CheckpointHeir) -> Pid {
  heir.pid
}

@internal
pub fn checkpoint_registry_put_for_test(
  heir: CheckpointHeir,
  table: heirloom.Table(key, value),
) -> Nil {
  checkpoint_registry_put(heir.key, table)
}

@internal
pub fn checkpoint_registry_exists_for_test(heir: CheckpointHeir) -> Bool {
  case checkpoint_registry_get(heir.key) {
    Some(_) -> True
    None -> False
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    RecoverQueue(subject) -> {
      schedule_queue_recovery(subject)
      case state.draining {
        True -> actor.continue(state)
        False -> handle_message(state, Drain(subject))
      }
    }
    Drain(subject) ->
      case work_queue.take(state.inbox) {
        Error(Nil) -> actor.continue(State(..state, draining: False))
        Ok(#(lease, work)) -> {
          let next = handle_message(State(..state, draining: True), work)
          work_queue.release(state.inbox, lease)
          process.send(subject, Drain(subject))
          next
        }
      }
    Acquire(reservation, ip, limiter, owner, token, reply) -> {
      let #(state, outcome) =
        acquire_slot(state, reservation, ip, limiter, owner, token)
      let state = persist(state)
      reply(outcome)
      case outcome {
        Ok(_) -> Nil
        Error(Nil) -> complete_request(state.inbox, reservation)
      }
      actor.continue(state)
    }
    Bind(reservation, owner, reply) -> {
      let #(state, outcome) = bind_holder(state, reservation, owner)
      let state = persist(state)
      reply(outcome)
      actor.continue(state)
    }
    Complete(reservation, token) ->
      case reservation_token_active(token) {
        True -> actor.continue(state)
        False ->
          actor.continue(release_reservation(state, reservation) |> persist)
      }
    Release(reservation) ->
      actor.continue(release_reservation(state, reservation) |> persist)
    HolderDown(down) ->
      case down {
        process.ProcessDown(monitor, _pid, _reason) ->
          case dict.get(state.monitors, monitor) {
            Ok(reservation) ->
              actor.continue(release_reservation(state, reservation) |> persist)
            // Already explicitly released (or an unrelated monitor).
            Error(Nil) -> actor.continue(state)
          }
        process.PortDown(_, _, _) -> actor.continue(state)
      }
    Sweep(subject) -> {
      schedule_sweep(subject, state.connection_rate)
      actor.continue(sweep_idle_buckets(state) |> persist)
    }
    Stop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn acquire_slot(
  state: State,
  reservation: reference.Reference,
  ip: String,
  limiter: ConnectionLimiter,
  owner: Pid,
  reservation_token: ReservationToken,
) -> #(State, Result(Permit, Nil)) {
  use <- bool.guard(
    when: !process.is_alive(owner)
      || !reservation_token_active(reservation_token),
    return: #(state, Error(Nil)),
  )
  let current =
    dict.get(state.counts, ip)
    |> result.unwrap(0)
  let ip_full = state.max_per_ip > 0 && current >= state.max_per_ip
  let total_full = state.max_total > 0 && state.total >= state.max_total
  use <- bool.guard(when: ip_full || total_full, return: #(state, Error(Nil)))

  let #(state, connection_token) = take_connection_token(state, ip)
  case connection_token {
    Error(Nil) -> #(state, Error(Nil))
    Ok(Nil) -> {
      use <- bool.guard(
        when: !reservation_token_active(reservation_token),
        return: #(state, Error(Nil)),
      )
      let monitor = process.monitor(owner)
      #(
        State(
          ..state,
          total: state.total + 1,
          counts: dict.insert(state.counts, ip, current + 1),
          reservations: dict.insert(
            state.reservations,
            reservation,
            Reservation(ip:, owner:, monitor:, token: reservation_token),
          ),
          monitors: dict.insert(state.monitors, monitor, reservation),
        ),
        Ok(Permit(
          limiter: limiter,
          reservation: reservation,
          token: reservation_token,
        )),
      )
    }
  }
}

fn take_connection_token(
  state: State,
  ip: String,
) -> #(State, Result(Nil, Nil)) {
  case state.connection_rate {
    None -> #(state, Ok(Nil))
    Some(config) -> {
      let bucket =
        dict.get(state.rate_buckets, ip)
        |> result.map(fn(entry) { entry.bucket })
        |> result.lazy_unwrap(fn() { rate_limit.new_bucket(config) })
      let #(bucket, taken) = rate_limit.take(bucket)
      let entry = RateBucket(bucket: bucket, last_seen_ns: monotonic_time_ns())
      #(
        State(..state, rate_buckets: dict.insert(state.rate_buckets, ip, entry)),
        taken,
      )
    }
  }
}

fn sweep_idle_buckets(state: State) -> State {
  let now = monotonic_time_ns()
  State(
    ..state,
    rate_buckets: state.rate_buckets
      |> dict.filter(fn(_ip, entry) {
        now - entry.last_seen_ns < state.bucket_ttl_ns
      }),
  )
}

fn schedule_sweep(
  subject: Subject(Message),
  connection_rate: Option(rate_limit.RateLimitConfig),
) -> Nil {
  case connection_rate {
    None -> Nil
    Some(_) -> {
      let _timer =
        process.send_after(subject, bucket_sweep_interval_ms, Sweep(subject))
      Nil
    }
  }
}

/// Transfer a reservation to the connection process. Monitor the new owner
/// before dropping the old monitor so the reservation is never unowned.
fn bind_holder(
  state: State,
  reservation: reference.Reference,
  owner: Pid,
) -> #(State, Result(Nil, Nil)) {
  case dict.get(state.reservations, reservation) {
    Error(Nil) -> #(state, Error(Nil))
    Ok(Reservation(ip, current_owner, current_monitor, token)) ->
      case reservation_token_active(token), current_owner == owner {
        False, _ -> #(release_reservation(state, reservation), Error(Nil))
        True, True -> #(state, Ok(Nil))
        True, False -> {
          let monitor = process.monitor(owner)
          process.demonitor_process(current_monitor)
          #(
            State(
              ..state,
              reservations: dict.insert(
                state.reservations,
                reservation,
                Reservation(ip:, owner:, monitor:, token:),
              ),
              monitors: state.monitors
                |> dict.delete(current_monitor)
                |> dict.insert(monitor, reservation),
            ),
            Ok(Nil),
          )
        }
      }
  }
}

fn release_reservation(
  state: State,
  reservation: reference.Reference,
) -> State {
  case dict.get(state.reservations, reservation) {
    Error(Nil) -> state
    Ok(Reservation(ip, _owner, monitor, _token)) -> {
      complete_request(state.inbox, reservation)
      process.demonitor_process(monitor)
      State(
        ..release_slot(state, ip),
        reservations: dict.delete(state.reservations, reservation),
        monitors: dict.delete(state.monitors, monitor),
      )
    }
  }
}

/// Reclaim a slot in both dimensions: decrement the per-system total and the
/// per-IP count. Every acquire increments both, so every release (explicit or
/// via a holder's death) decrements both symmetrically.
fn release_slot(state: State, ip: String) -> State {
  let total = int.max(state.total - 1, 0)
  case dict.get(state.counts, ip) {
    Ok(count) if count > 1 ->
      State(
        ..state,
        total: total,
        counts: dict.insert(state.counts, ip, count - 1),
      )
    Ok(_) | Error(Nil) ->
      State(..state, total: total, counts: dict.delete(state.counts, ip))
  }
}

fn recover_holders(state: State) -> State {
  let reservations = dict.to_list(state.reservations)
  let state = State(..state, reservations: dict.new(), monitors: dict.new())
  list.fold(reservations, state, fn(state, entry) {
    let #(reservation, Reservation(ip, owner, _old_monitor, token)) = entry
    // A reply from the old worker must not grant a slot after recovery dropped
    // it. This races atomically with the caller acknowledging that reply.
    let _cancelled =
      atomic.compare_exchange(token, pending_token, cancelled_token)
    case process.is_alive(owner) && reservation_token_active(token) {
      True -> {
        let monitor = process.monitor(owner)
        State(
          ..state,
          reservations: dict.insert(
            state.reservations,
            reservation,
            Reservation(ip:, owner:, monitor:, token:),
          ),
          monitors: dict.insert(state.monitors, monitor, reservation),
        )
      }
      False -> release_slot(state, ip)
    }
  })
}

fn request(limiter: ConnectionLimiter, ip: String) -> Result(Permit, Nil) {
  use inbox <- result.try(
    work_queue.lookup(limiter.name) |> result.replace_error(Nil),
  )
  let reservation = reference.new()
  let token = new_reservation_token()
  let outcome = case
    work_queue.call_with_cleanup(
      inbox,
      reservation,
      registry_call_timeout_ms,
      fn(reply) {
        Acquire(
          reservation: reservation,
          ip: ip,
          limiter: limiter,
          owner: process.self(),
          token: token,
          reply: reply,
        )
      },
      Complete(reservation, token),
    )
  {
    Ok(Ok(permit)) ->
      case atomic.compare_exchange(token, pending_token, accepted_token) {
        Ok(Nil) -> Ok(permit)
        Error(_) -> Error(Nil)
      }
    Ok(Error(Nil)) -> Error(Nil)
    Error(_) -> {
      let _cancelled = cancel_reservation_token(token)
      Error(Nil)
    }
  }
  complete_request(inbox, reservation)
  outcome
}

fn complete_request(
  inbox: work_queue.Queue(Message),
  reservation: reference.Reference,
) -> Nil {
  case work_queue.activate_cleanup(inbox, reservation) {
    Ok(Nil) | Error(overload.Unavailable) -> Nil
    Error(error) ->
      log.warn(
        log.new("beryl.connection_limit"),
        "Connection cleanup activation failed",
        [#("reason", overload.describe(error))],
      )
  }
}

fn schedule_queue_recovery(subject: Subject(Message)) -> Nil {
  let _timer =
    process.send_after(
      subject,
      queue_recovery_interval_ms,
      RecoverQueue(subject),
    )
  Nil
}

fn build(
  max_per_ip: Int,
  max_total: Int,
  connection_rate: Int,
  connection_burst: Int,
  queue_limits: overload.Limits,
  name: process.Name(Message),
) -> actor.Builder(State, Message, Subject(Message)) {
  let rate_config = case connection_rate > 0 {
    True ->
      Some(rate_limit.config(
        per_second: connection_rate,
        burst: connection_burst,
      ))
    False -> None
  }
  let effective_burst = case connection_burst {
    0 -> connection_rate
    burst -> burst
  }
  actor.new_with_initialiser(1000, fn(subject) {
    let inbox =
      work_queue.new(queue_limits, overload.ConnectionQueue, False, fn() {
        process.send(subject, Drain(subject))
      })
    work_queue.name(inbox, name)
    let state =
      State(
        store_key: name,
        inbox: inbox,
        draining: False,
        checkpoint: None,
        max_per_ip: max_per_ip,
        max_total: max_total,
        connection_rate: rate_config,
        bucket_ttl_ns: int.max(
          bucket_sweep_interval_ms * 1_000_000,
          effective_burst * one_second_ns / int.max(connection_rate, 1),
        ),
        total: 0,
        counts: dict.new(),
        rate_buckets: dict.new(),
        reservations: dict.new(),
        monitors: dict.new(),
      )
    schedule_sweep(subject, rate_config)
    schedule_queue_recovery(subject)
    let state = open_state(name, state)
    let state =
      State(..state, inbox: inbox, draining: False)
      |> recover_holders
      |> persist
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(HolderDown)
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
}

@internal
pub fn start_named(
  max_per_ip: Int,
  max_total: Int,
  connection_rate: Int,
  connection_burst: Int,
  queue_limits: overload.Limits,
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  build(
    max_per_ip,
    max_total,
    connection_rate,
    connection_burst,
    queue_limits,
    name,
  )
  |> actor.named(name)
  |> actor.start
}

@internal
pub fn from_name(name: process.Name(Message)) -> ConnectionLimiter {
  ConnectionLimiter(subject: process.named_subject(name), name: name)
}

/// The pid of the limiter process, if it is currently running. Used by the
/// runtime subtree teardown to wait for the limiter to terminate.
@internal
pub fn pid(limiter: ConnectionLimiter) -> Result(Pid, Nil) {
  process.subject_owner(limiter.subject)
}

/// Inspect pending admission without sending a message to the limiter.
@internal
pub fn queue_snapshot(
  limiter: ConnectionLimiter,
) -> Result(overload.Occupancy, overload.AdmissionError) {
  use inbox <- result.try(work_queue.lookup(limiter.name))
  work_queue.snapshot(inbox)
}

@internal
pub fn enabled(max_per_ip: Int, max_total: Int, connection_rate: Int) -> Bool {
  max_per_ip > 0 || max_total > 0 || connection_rate > 0
}

/// Acquire a connection slot, failing when the IP already has too many sockets.
fn acquire(limiter: ConnectionLimiter, ip: String) -> Result(Permit, Nil) {
  request(limiter, ip)
}

/// Acquire from an optional limiter. `None` means unlimited.
pub fn acquire_optional(
  limiter: Option(ConnectionLimiter),
  ip: String,
) -> Result(Option(Permit), Nil) {
  case limiter {
    None -> Ok(None)
    Some(limiter) -> acquire(limiter, ip) |> result.map(Some)
  }
}

/// Bind a permit to the calling process (the long-lived connection process),
/// so its slot is reclaimed if that process dies without releasing.
fn bind(permit: Permit) -> Result(Nil, Nil) {
  let outcome = bind_request(permit)
  case outcome {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> {
      release(permit)
      Error(Nil)
    }
  }
}

fn bind_request(permit: Permit) -> Result(Nil, Nil) {
  use inbox <- result.try(
    work_queue.lookup(permit.limiter.name) |> result.replace_error(Nil),
  )
  case
    work_queue.call(inbox, registry_call_timeout_ms, fn(reply) {
      Bind(permit.reservation, process.self(), reply)
    })
  {
    Ok(outcome) -> outcome
    Error(_) -> Error(Nil)
  }
}

/// Bind a slot to the calling process if one was acquired.
pub fn bind_optional(permit: Option(Permit)) -> Result(Nil, Nil) {
  case permit {
    Some(permit) -> bind(permit)
    None -> Ok(Nil)
  }
}

/// Release a previously acquired slot.
fn release(permit: Permit) -> Nil {
  use <- bool.guard(when: !cancel_reservation_token(permit.token), return: Nil)
  process.send(permit.limiter.subject, Release(permit.reservation))
}

/// Release a slot if one was acquired.
pub fn release_optional(permit: Option(Permit)) -> Nil {
  case permit {
    Some(permit) -> release(permit)
    None -> Nil
  }
}
