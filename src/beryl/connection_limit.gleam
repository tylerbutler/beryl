//// Shared per-IP connection counter for transports.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

const registry_call_timeout_ms = 100

/// Opaque connection limiter registry.
pub opaque type ConnectionLimiter {
  ConnectionLimiter(subject: Subject(Message))
}

/// A checked-out connection slot. Release it when the socket closes.
pub opaque type Permit {
  Permit(limiter: ConnectionLimiter, ip: String)
}

type State {
  State(
    max_per_ip: Int,
    counts: Dict(String, Int),
    /// Monitors on bound permit-holder processes, so slots self-release when
    /// the holder dies without running its close path (crash, brutal kill).
    monitors: Dict(Monitor, #(Pid, String)),
    /// Reverse index from holder pid to its monitor, so an explicit release
    /// can drop the monitor and never double-decrement.
    holders: Dict(Pid, Monitor),
  )
}

type Message {
  Acquire(
    ip: String,
    limiter: ConnectionLimiter,
    reply: Subject(Result(Permit, Nil)),
  )
  Bind(ip: String, owner: Pid)
  Release(ip: String, owner: Pid)
  HolderDown(down: process.Down)
  Stop(reply: Subject(Nil))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Acquire(ip, limiter, reply) -> {
      let current =
        dict.get(state.counts, ip)
        |> result.unwrap(0)

      case current >= state.max_per_ip {
        True -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        False -> {
          process.send(reply, Ok(Permit(limiter: limiter, ip: ip)))
          actor.continue(
            State(..state, counts: dict.insert(state.counts, ip, current + 1)),
          )
        }
      }
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
      actor.continue(release_ip(state, ip))
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
              actor.continue(release_ip(state, ip))
            }
            // Already explicitly released (or an unrelated monitor).
            Error(Nil) -> actor.continue(state)
          }
        process.PortDown(_, _, _) -> actor.continue(state)
      }
    Stop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
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

fn release_ip(state: State, ip: String) -> State {
  case dict.get(state.counts, ip) {
    Ok(count) if count > 1 ->
      State(..state, counts: dict.insert(state.counts, ip, count - 1))
    _ -> State(..state, counts: dict.delete(state.counts, ip))
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

/// Start a connection limiter with a maximum active connection count per IP.
fn start(max_per_ip: Int) -> Result(ConnectionLimiter, actor.StartError) {
  let state =
    State(
      max_per_ip: max_per_ip,
      counts: dict.new(),
      monitors: dict.new(),
      holders: dict.new(),
    )
  actor.new_with_initialiser(1000, fn(subject) {
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
  |> actor.start
  |> result.map(fn(started) { ConnectionLimiter(subject: started.data) })
}

/// Start a limiter only when `max_per_ip` is positive.
pub fn start_optional(max_per_ip: Int) -> Option(ConnectionLimiter) {
  use <- bool.guard(when: max_per_ip <= 0, return: None)
  let assert Ok(limiter) = start(max_per_ip)
  Some(limiter)
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

fn stop(limiter: ConnectionLimiter) -> Nil {
  let should_send = case process.subject_owner(limiter.subject) {
    Error(Nil) -> False
    Ok(pid) -> process.is_alive(pid)
  }

  use <- bool.guard(when: !should_send, return: Nil)
  let reply = process.new_subject()
  process.send(limiter.subject, Stop(reply))
  let _stop_result = process.receive(reply, registry_call_timeout_ms)
  Nil
}

/// Stop the connection limiter if one is present; a no-op when `None`.
pub fn stop_optional(limiter: Option(ConnectionLimiter)) -> Nil {
  case limiter {
    Some(limiter) -> stop(limiter)
    None -> Nil
  }
}
