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
//// dies without releasing. Rate buckets remain in this supervisor-held actor
//// across reconnects and runtime restarts, then expire once idle long enough
//// to have fully refilled.

import beryl/rate_limit
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

const registry_call_timeout_ms = 100

const bucket_sweep_interval_ms = 60_000

const one_second_ns = 1_000_000_000

/// Erlang monotonic time in nanoseconds.
@external(erlang, "beryl_ffi", "monotonic_time_ns")
fn monotonic_time_ns() -> Int

/// Opaque connection limiter registry.
pub opaque type ConnectionLimiter {
  ConnectionLimiter(subject: Subject(Message))
}

/// A checked-out connection slot. Release it when the socket closes.
pub opaque type Permit {
  Permit(limiter: ConnectionLimiter, ip: String)
}

type RateBucket {
  RateBucket(bucket: rate_limit.Bucket, last_seen_ns: Int)
}

type State {
  State(
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
    /// Monitors on bound permit-holder processes, so slots self-release when
    /// the holder dies without running its close path (crash, brutal kill).
    monitors: Dict(Monitor, #(Pid, String)),
    /// Reverse index from holder pid to its monitor, so an explicit release
    /// can drop the monitor and never double-decrement.
    holders: Dict(Pid, Monitor),
  )
}

pub opaque type Message {
  Acquire(
    ip: String,
    limiter: ConnectionLimiter,
    reply: Subject(Result(Permit, Nil)),
  )
  Bind(ip: String, owner: Pid)
  Release(ip: String, owner: Pid)
  HolderDown(down: process.Down)
  Sweep(subject: Subject(Message))
  Stop(reply: Subject(Nil))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Acquire(ip, limiter, reply) -> {
      let #(state, outcome) = acquire_slot(state, ip, limiter)
      process.send(reply, outcome)
      actor.continue(state)
    }
    Bind(ip, owner) -> actor.continue(bind_holder(state, ip, owner))
    Release(ip, owner) -> {
      // Drop the holder's monitor (when bound) before decrementing, so a
      // later exit of the same process cannot decrement this IP twice.
      let state = case dict.get(state.holders, owner) {
        Ok(monitor) -> {
          process.demonitor_process(monitor)
          State(
            ..state,
            monitors: dict.delete(state.monitors, monitor),
            holders: dict.delete(state.holders, owner),
          )
        }
        Error(Nil) -> state
      }
      actor.continue(release_slot(state, ip))
    }
    HolderDown(down) ->
      case down {
        process.ProcessDown(monitor, pid, _reason) ->
          case dict.get(state.monitors, monitor) {
            Ok(#(_owner, ip)) -> {
              let state =
                State(
                  ..state,
                  monitors: dict.delete(state.monitors, monitor),
                  holders: dict.delete(state.holders, pid),
                )
              actor.continue(release_slot(state, ip))
            }
            // Already explicitly released (or an unrelated monitor).
            Error(Nil) -> actor.continue(state)
          }
        process.PortDown(_, _, _) -> actor.continue(state)
      }
    Sweep(subject) -> {
      schedule_sweep(subject, state.connection_rate)
      actor.continue(sweep_idle_buckets(state))
    }
    Stop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn acquire_slot(
  state: State,
  ip: String,
  limiter: ConnectionLimiter,
) -> #(State, Result(Permit, Nil)) {
  let current =
    dict.get(state.counts, ip)
    |> result.unwrap(0)
  let ip_full = state.max_per_ip > 0 && current >= state.max_per_ip
  let total_full = state.max_total > 0 && state.total >= state.max_total
  use <- bool.guard(when: ip_full || total_full, return: #(state, Error(Nil)))

  let #(state, token) = take_connection_token(state, ip)
  case token {
    Error(Nil) -> #(state, Error(Nil))
    Ok(Nil) -> #(
      State(
        ..state,
        total: state.total + 1,
        counts: dict.insert(state.counts, ip, current + 1),
      ),
      Ok(Permit(limiter: limiter, ip: ip)),
    )
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

/// Monitor a permit holder so its slot is reclaimed if the process dies
/// without releasing. Rebinding the same pid is a no-op.
fn bind_holder(state: State, ip: String, owner: Pid) -> State {
  use <- bool.guard(when: dict.has_key(state.holders, owner), return: state)
  let monitor = process.monitor(owner)
  State(
    ..state,
    monitors: dict.insert(state.monitors, monitor, #(owner, ip)),
    holders: dict.insert(state.holders, owner, monitor),
  )
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
    _ -> State(..state, total: total, counts: dict.delete(state.counts, ip))
  }
}

fn request(
  subject: Subject(Message),
  build_message: fn(Subject(Result(Permit, Nil))) -> Message,
) -> Result(Permit, Nil) {
  case process.subject_owner(subject) {
    Error(Nil) -> Error(Nil)
    Ok(_) -> {
      let reply_subject = process.new_subject()
      process.send(subject, build_message(reply_subject))
      case process.receive(reply_subject, registry_call_timeout_ms) {
        Ok(value) -> value
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

fn build(
  max_per_ip: Int,
  max_total: Int,
  connection_rate: Int,
  connection_burst: Int,
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
      monitors: dict.new(),
      holders: dict.new(),
    )
  actor.new_with_initialiser(1000, fn(subject) {
    schedule_sweep(subject, rate_config)
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
  build(max_per_ip, max_total, connection_rate, connection_burst)
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
  request(limiter.subject, fn(reply) {
    Acquire(ip: ip, limiter: limiter, reply: reply)
  })
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
fn bind(permit: Permit) -> Nil {
  process.send(permit.limiter.subject, Bind(permit.ip, process.self()))
}

/// Bind a slot to the calling process if one was acquired.
pub fn bind_optional(permit: Option(Permit)) -> Nil {
  case permit {
    Some(permit) -> bind(permit)
    None -> Nil
  }
}

/// Release a previously acquired slot.
///
/// Call from the process the permit was bound to (or from an unbound
/// process, e.g. when the handshake fails before binding).
fn release(permit: Permit) -> Nil {
  process.send(permit.limiter.subject, Release(permit.ip, process.self()))
}

/// Release a slot if one was acquired.
pub fn release_optional(permit: Option(Permit)) -> Nil {
  case permit {
    Some(permit) -> release(permit)
    None -> Nil
  }
}
