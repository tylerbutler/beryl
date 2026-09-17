//// Shared connection admission controls for transports.
////
//// Enforces three independent dimensions in a single serialized actor:
////
//// - a per-IP ceiling (`max_per_ip`), which throttles a single peer, and
//// - a node-wide ceiling (`max_total`), which caps concurrent connections
////   across every IP so distributed/rotating source addresses cannot exhaust
////   the node's process, socket, and runtime budget, and
//// - a per-IP token bucket, which prevents reconnect churn from repeatedly
////   refreshing per-connection frame and message bursts.
////
//// All three are checked atomically inside `handle_message` on acquire, so
//// concurrent opens cannot race past either ceiling. A single `Permit` tracks
//// both dimensions and the same process monitor reclaims both when the holder
//// dies without releasing. Counts and rate buckets are checkpointed to an ETS
//// table with a supervisor-scoped heir, so they survive reconnects and worker
//// restarts, then expire once idle long enough to have fully refilled.

import beryl/rate_limit
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

const registry_call_timeout_ms = 100

const bucket_sweep_interval_ms = 60_000

const one_second_ns = 1_000_000_000

/// Erlang monotonic time in nanoseconds.
@external(erlang, "beryl_ffi", "monotonic_time_ns")
fn monotonic_time_ns() -> Int

type ReservationToken

@external(erlang, "beryl_ffi", "admission_token_new")
fn new_reservation_token() -> ReservationToken

@external(erlang, "beryl_ffi", "admission_token_cancel")
fn cancel_reservation_token(token: ReservationToken) -> Bool

@external(erlang, "beryl_ffi", "reservation_token_pending")
fn reservation_token_pending(token: ReservationToken) -> Bool

type CallError {
  CallTimedOut
  CallOwnerUnavailable
}

@external(erlang, "beryl_ffi", "connection_limit_call")
fn call(
  subject: Subject(Message),
  timeout_ms: Int,
  request: fn(Subject(reply)) -> Message,
) -> Result(reply, CallError)

@external(erlang, "beryl_ffi", "connection_limit_send")
fn send_if_alive(subject: Subject(Message), message: Message) -> Bool

/// Opaque connection limiter registry.
pub opaque type ConnectionLimiter {
  ConnectionLimiter(subject: Subject(Message))
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

type State {
  State(
    store_key: process.Name(Message),
    /// Per-IP ceiling; 0 disables the per-IP check.
    max_per_ip: Int,
    /// Node-wide ceiling across all IPs; 0 disables the global check.
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
    reply: Subject(Result(Permit, Nil)),
  )
  Bind(
    reservation: reference.Reference,
    owner: Pid,
    reply: Subject(Result(Nil, Nil)),
  )
  Cancel(reservation: reference.Reference)
  Release(reservation: reference.Reference)
  HolderDown(down: process.Down)
  Sweep(subject: Subject(Message))
  Stop(reply: Subject(Nil))
}

@external(erlang, "beryl_ffi", "connection_limit_state_open")
fn open_state(store_key: process.Name(Message), initial: State) -> State

@external(erlang, "beryl_ffi", "connection_limit_state_put")
fn put_state(store_key: process.Name(Message), state: State) -> Nil

fn persist(state: State) -> State {
  put_state(state.store_key, state)
  state
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Acquire(reservation, ip, limiter, owner, token, reply) -> {
      let #(state, outcome) =
        acquire_slot(state, reservation, ip, limiter, owner, token)
      let state = persist(state)
      process.send(reply, outcome)
      actor.continue(state)
    }
    Bind(reservation, owner, reply) -> {
      let #(state, outcome) = bind_holder(state, reservation, owner)
      let state = persist(state)
      process.send(reply, outcome)
      actor.continue(state)
    }
    Cancel(reservation) | Release(reservation) ->
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
      || !reservation_token_pending(reservation_token),
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
        when: !reservation_token_pending(reservation_token),
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
      case reservation_token_pending(token), current_owner == owner {
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
      process.demonitor_process(monitor)
      State(
        ..release_slot(state, ip),
        reservations: dict.delete(state.reservations, reservation),
        monitors: dict.delete(state.monitors, monitor),
      )
    }
  }
}

/// Reclaim a slot in both dimensions: decrement the node-wide total and the
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
    case process.is_alive(owner) && reservation_token_pending(token) {
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

fn request(
  limiter: ConnectionLimiter,
  ip: String,
  subject: Subject(Message),
) -> Result(Permit, Nil) {
  let reservation = reference.new()
  let token = new_reservation_token()
  case
    call(subject, registry_call_timeout_ms, fn(reply_subject) {
      Acquire(
        reservation: reservation,
        ip: ip,
        limiter: limiter,
        owner: process.self(),
        token: token,
        reply: reply_subject,
      )
    })
  {
    Ok(value) -> value
    Error(CallTimedOut) -> {
      let _cancelled = cancel_reservation_token(token)
      // Signals from one process arrive in order. If Acquire is still queued,
      // this cancellation follows it and reclaims any late slot.
      let _sent = send_if_alive(subject, Cancel(reservation))
      Error(Nil)
    }
    Error(CallOwnerUnavailable) -> {
      let _cancelled = cancel_reservation_token(token)
      Error(Nil)
    }
  }
}

fn build(
  max_per_ip: Int,
  max_total: Int,
  connection_rate: Int,
  connection_burst: Int,
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
  let state =
    State(
      store_key: name,
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
  actor.new_with_initialiser(1000, fn(subject) {
    schedule_sweep(subject, rate_config)
    let state = open_state(name, state) |> recover_holders |> persist
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
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  build(max_per_ip, max_total, connection_rate, connection_burst, name)
  |> actor.named(name)
  |> actor.start
}

@internal
pub fn from_name(name: process.Name(Message)) -> ConnectionLimiter {
  ConnectionLimiter(subject: process.named_subject(name))
}

/// The pid of the limiter process, if it is currently running. Used by the
/// runtime subtree teardown to wait for the limiter to terminate.
@internal
pub fn pid(limiter: ConnectionLimiter) -> Result(Pid, Nil) {
  process.subject_owner(limiter.subject)
}

@internal
pub fn enabled(max_per_ip: Int, max_total: Int, connection_rate: Int) -> Bool {
  max_per_ip > 0 || max_total > 0 || connection_rate > 0
}

/// Acquire a connection slot, failing when the IP already has too many sockets.
fn acquire(limiter: ConnectionLimiter, ip: String) -> Result(Permit, Nil) {
  request(limiter, ip, limiter.subject)
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
  case
    call(permit.limiter.subject, registry_call_timeout_ms, fn(reply) {
      Bind(permit.reservation, process.self(), reply)
    })
  {
    Ok(outcome) -> outcome
    Error(CallTimedOut) | Error(CallOwnerUnavailable) -> Error(Nil)
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
  let _cancelled = cancel_reservation_token(permit.token)
  process.send(permit.limiter.subject, Release(permit.reservation))
}

/// Release a slot if one was acquired.
pub fn release_optional(permit: Option(Permit)) -> Nil {
  case permit {
    Some(permit) -> release(permit)
    None -> Nil
  }
}
