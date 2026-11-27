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
//// A supervised manager creates the private table and gives ownership to the
//// limiter. It inherits the table when the limiter exits and gives it to the
//// replacement. A manager failure restarts the limiter with empty state.
//// State also ends with the enclosing beryl supervisor or node.
//// An established checkpoint without state fails worker initialisation.

import beryl/log
import beryl/overload
import beryl/rate_limit
import beryl/work_queue
import beryl_heirloom as heirloom
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import rasa/atomic
import rasa/monotonic

const registry_call_timeout_ms = 100

const checkpoint_handoff_timeout_ms = 900

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

type CheckpointOrigin {
  FreshCheckpoint
  EstablishedCheckpoint
}

type CheckpointError {
  MissingCheckpointState
  CheckpointLookupFailed(heirloom.TableError)
  CheckpointWriteFailed(heirloom.TableError)
  CheckpointHeirFailed(heirloom.OwnershipError)
  CheckpointTransferFailed(heirloom.TransferDecodeError)
  CheckpointManagerUnavailable
  CheckpointHandoffTimedOut
  UnexpectedCheckpointTransfer
}

@internal
pub opaque type CheckpointMessage {
  ClaimCheckpoint(Pid)
  CheckpointTransferred(
    Result(heirloom.Transfer(String, State, Bool), heirloom.TransferDecodeError),
  )
  CheckpointClaimantDown(process.Down)
}

type CheckpointState {
  CheckpointAvailable(table: CheckpointTable, origin: CheckpointOrigin)
  CheckpointHeld(
    table: CheckpointTable,
    holder: Pid,
    pending: Option(PendingClaim),
  )
}

type PendingClaim {
  PendingClaim(pid: Pid, monitor: Monitor)
}

type State {
  State(
    inbox: work_queue.Queue(Message),
    draining: Bool,
    checkpoint: CheckpointTable,
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

fn persist(state: State) -> Result(State, CheckpointError) {
  heirloom.insert(state.checkpoint, "state", state)
  |> result.map(fn(_) { state })
  |> result.map_error(CheckpointWriteFailed)
}

fn continue_persisted(state: State) -> actor.Next(State, Message) {
  case persist(state) {
    Ok(state) -> actor.continue(state)
    Error(error) -> actor.stop_abnormal(checkpoint_error_message(error))
  }
}

fn open_state(
  initial: State,
  origin: CheckpointOrigin,
) -> Result(State, CheckpointError) {
  case heirloom.lookup(initial.checkpoint, "state"), origin {
    Ok(Some(state)), _ -> Ok(State(..state, checkpoint: initial.checkpoint))
    Ok(None), FreshCheckpoint -> Ok(initial)
    Ok(None), EstablishedCheckpoint -> Error(MissingCheckpointState)
    Error(error), _ -> Error(CheckpointLookupFailed(error))
  }
}

fn checkpoint_error_message(error: CheckpointError) -> String {
  case error {
    MissingCheckpointState -> "Connection limiter checkpoint state is missing"
    CheckpointLookupFailed(heirloom.TableDoesNotExist)
    | CheckpointWriteFailed(heirloom.TableDoesNotExist) ->
      "Connection limiter checkpoint table does not exist"
    CheckpointLookupFailed(heirloom.AccessDenied)
    | CheckpointWriteFailed(heirloom.AccessDenied) ->
      "Connection limiter checkpoint access denied"
    CheckpointHeirFailed(error) -> ownership_error_message(error)
    CheckpointTransferFailed(_) ->
      "Invalid connection limiter checkpoint transfer"
    CheckpointManagerUnavailable ->
      "Connection limiter checkpoint manager is unavailable"
    CheckpointHandoffTimedOut ->
      "Connection limiter checkpoint transfer timed out"
    UnexpectedCheckpointTransfer ->
      "Unexpected connection limiter checkpoint transfer"
  }
}

fn ownership_error_message(error: heirloom.OwnershipError) -> String {
  case error {
    heirloom.OwnershipTableDoesNotExist ->
      "Connection limiter checkpoint table does not exist"
    heirloom.NotOwner ->
      "Connection limiter checkpoint is not owned by the caller"
    heirloom.InvalidOwnershipHeir ->
      "Connection limiter checkpoint heir is unavailable"
    heirloom.RecipientNotAlive ->
      "Connection limiter checkpoint claimant has exited"
    heirloom.RecipientNotLocal ->
      "Connection limiter checkpoint claimant is not local"
    heirloom.RecipientIsOwner ->
      "Connection limiter checkpoint claimant already owns the table"
  }
}

fn checkpoint_origin(established: Bool) -> CheckpointOrigin {
  use <- bool.guard(established, EstablishedCheckpoint)
  FreshCheckpoint
}

fn give_checkpoint(
  table: CheckpointTable,
  origin: CheckpointOrigin,
  claimant: Pid,
) -> actor.Next(CheckpointState, CheckpointMessage) {
  case heirloom.give_away(table, claimant, origin == EstablishedCheckpoint) {
    Ok(Nil) -> actor.continue(CheckpointHeld(table, claimant, None))
    Error(heirloom.RecipientNotAlive) ->
      actor.continue(CheckpointAvailable(table, origin))
    Error(error) -> actor.stop_abnormal(ownership_error_message(error))
  }
}

fn retain_checkpoint_claim(
  table: CheckpointTable,
  holder: Pid,
  pending: Option(PendingClaim),
  claimant: Pid,
) -> actor.Next(CheckpointState, CheckpointMessage) {
  case pending {
    Some(PendingClaim(pid, _)) if pid == claimant ->
      actor.continue(CheckpointHeld(table, holder, pending))
    Some(PendingClaim(pid, monitor)) ->
      case process.is_alive(pid) {
        True -> {
          log.warn(
            log.new("beryl.connection_limit"),
            "Duplicate checkpoint claim ignored",
            [],
          )
          actor.continue(CheckpointHeld(table, holder, pending))
        }
        False -> {
          process.demonitor_process(monitor)
          retain_checkpoint_claim(table, holder, None, claimant)
        }
      }
    None ->
      case process.is_alive(claimant) {
        True ->
          actor.continue(CheckpointHeld(
            table,
            holder,
            Some(PendingClaim(claimant, process.monitor(claimant))),
          ))
        False -> actor.continue(CheckpointHeld(table, holder, None))
      }
  }
}

fn handle_checkpoint_message(
  state: CheckpointState,
  message: CheckpointMessage,
) -> actor.Next(CheckpointState, CheckpointMessage) {
  case message, state {
    ClaimCheckpoint(claimant), CheckpointAvailable(table, origin) ->
      give_checkpoint(table, origin, claimant)
    ClaimCheckpoint(claimant), CheckpointHeld(table, holder, pending) ->
      retain_checkpoint_claim(table, holder, pending, claimant)
    CheckpointTransferred(Ok(heirloom.Transfer(table, previous_owner, data))),
      CheckpointHeld(expected, holder, pending)
      if table == expected && previous_owner == holder
    ->
      case heirloom.owner(table) == Ok(process.self()), pending {
        True, Some(PendingClaim(pid, monitor)) -> {
          process.demonitor_process(monitor)
          give_checkpoint(table, checkpoint_origin(data), pid)
        }
        True, None ->
          actor.continue(CheckpointAvailable(table, checkpoint_origin(data)))
        False, _ -> actor.continue(state)
      }
    CheckpointTransferred(_), _ -> {
      log.warn(
        log.new("beryl.connection_limit"),
        "Invalid ETS transfer ignored",
        [],
      )
      actor.continue(state)
    }
    CheckpointClaimantDown(process.ProcessDown(monitor, _, _)),
      CheckpointHeld(table, holder, Some(PendingClaim(_, expected)))
      if monitor == expected
    -> actor.continue(CheckpointHeld(table, holder, None))
    CheckpointClaimantDown(_), _ -> actor.continue(state)
  }
}

/// Start the supervised owner that retains the checkpoint between workers.
@internal
pub fn start_checkpoint_manager(
  name: process.Name(CheckpointMessage),
) -> Result(actor.Started(Subject(CheckpointMessage)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let specification =
      heirloom.spec("beryl_connection_limit_state", heirloom.Set)
      |> heirloom.with_access(heirloom.Private)
      |> heirloom.with_heir(process.self(), False)
    use table <- result.try(
      heirloom.create(specification)
      |> result.map_error(fn(error) {
        case error {
          heirloom.TableAlreadyExists ->
            "Connection limiter checkpoint already exists"
          heirloom.InvalidName -> "Invalid connection limiter checkpoint name"
          heirloom.InvalidHeir -> "Invalid connection limiter checkpoint heir"
          heirloom.InvalidOptions ->
            "Invalid connection limiter checkpoint options"
        }
      }),
    )
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(CheckpointClaimantDown)
      |> heirloom.select_transfers(decode.bool, CheckpointTransferred)
    actor.initialised(CheckpointAvailable(table, FreshCheckpoint))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_checkpoint_message)
  |> actor.named(name)
  |> actor.start
}

/// Claim ownership for one worker incarnation.
@internal
pub fn claim_checkpoint(
  manager: Subject(CheckpointMessage),
  claimant: Pid,
) -> Nil {
  process.send(manager, ClaimCheckpoint(claimant))
}

fn receive_checkpoint(
  manager: Subject(CheckpointMessage),
) -> Result(#(CheckpointTable, CheckpointOrigin, Pid), CheckpointError) {
  use #(manager, owner) <- result.try(
    pin_subject(manager) |> result.replace_error(CheckpointManagerUnavailable),
  )
  let monitor = process.monitor(owner)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) {
      Error(CheckpointManagerUnavailable)
    })
    |> heirloom.select_transfers(decode.bool, fn(transfer) {
      result.map_error(transfer, CheckpointTransferFailed)
    })
  claim_checkpoint(manager, process.self())
  let received =
    process.selector_receive(selector, checkpoint_handoff_timeout_ms)
  process.demonitor_process(monitor)
  use received <- result.try(result.replace_error(
    received,
    CheckpointHandoffTimedOut,
  ))
  use transfer <- result.try(received)
  case transfer {
    heirloom.Transfer(table, previous_owner, data) if previous_owner == owner ->
      case heirloom.owner(table) == Ok(process.self()) {
        True -> Ok(#(table, checkpoint_origin(data), owner))
        False -> Error(UnexpectedCheckpointTransfer)
      }
    heirloom.Transfer(..) -> Error(UnexpectedCheckpointTransfer)
  }
}

/// Construct the manager and limiter's shared restart boundary.
@internal
pub fn child_spec(
  max_per_ip: Int,
  max_total: Int,
  connection_rate: Int,
  connection_burst: Int,
  queue_limits: overload.Limits,
  name: process.Name(Message),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let manager_name = process.new_name("beryl_connection_checkpoint")
  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
  |> static_supervisor.add(
    supervision.worker(fn() { start_checkpoint_manager(manager_name) }),
  )
  |> static_supervisor.add(
    supervision.worker(fn() {
      start_named(
        max_per_ip,
        max_total,
        connection_rate,
        connection_burst,
        queue_limits,
        name,
        process.named_subject(manager_name),
      )
    }),
  )
  |> static_supervisor.supervised
}

fn reply_to_acquire(
  inbox: work_queue.Queue(Message),
  reservation: reference.Reference,
  outcome: Result(Permit, Nil),
  reply: fn(Result(Permit, Nil)) -> Nil,
) -> Nil {
  reply(outcome)
  case outcome {
    Ok(_) -> Nil
    Error(Nil) -> complete_request(inbox, reservation)
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    RecoverQueue(subject) -> {
      schedule_queue_recovery(subject)
      case persist_cancelled_holders(state) {
        Ok(state) ->
          case state.draining {
            True -> actor.continue(state)
            False -> handle_message(state, Drain(subject))
          }
        Error(error) -> actor.stop_abnormal(checkpoint_error_message(error))
      }
    }
    Drain(subject) ->
      case work_queue.take(state.inbox) {
        Error(work_queue.Empty) ->
          actor.continue(State(..state, draining: False))
        Error(work_queue.Yielded) -> {
          process.send(subject, Drain(subject))
          actor.continue(State(..state, draining: True))
        }
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
      case persist(state) {
        Ok(state) -> {
          reply_to_acquire(state.inbox, reservation, outcome, reply)
          actor.continue(state)
        }
        Error(error) -> actor.stop_abnormal(checkpoint_error_message(error))
      }
    }
    Bind(reservation, owner, reply) -> {
      let #(state, outcome) = bind_holder(state, reservation, owner)
      case persist(state) {
        Ok(state) -> {
          reply(outcome)
          actor.continue(state)
        }
        Error(error) -> actor.stop_abnormal(checkpoint_error_message(error))
      }
    }
    Complete(reservation, token) ->
      case reservation_token_active(token) {
        True -> actor.continue(state)
        False -> continue_persisted(release_reservation(state, reservation))
      }
    Release(reservation) ->
      continue_persisted(release_reservation(state, reservation))
    HolderDown(down) ->
      case down {
        process.ProcessDown(monitor, _pid, _reason) ->
          case dict.get(state.monitors, monitor) {
            Ok(reservation) ->
              continue_persisted(release_reservation(state, reservation))
            // Already explicitly released (or an unrelated monitor).
            Error(Nil) -> actor.continue(state)
          }
        process.PortDown(_, _, _) -> actor.continue(state)
      }
    Sweep(subject) -> {
      schedule_sweep(subject, state.connection_rate)
      continue_persisted(sweep_idle_buckets(state))
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
  let state = case at_capacity(state, ip) {
    // A queued drain can overtake Release, but its token is already cancelled.
    True -> reclaim_cancelled_holders(state)
    False -> state
  }
  use <- bool.guard(when: at_capacity(state, ip), return: #(state, Error(Nil)))
  let current =
    dict.get(state.counts, ip)
    |> result.unwrap(0)

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

fn at_capacity(state: State, ip: String) -> Bool {
  let current = dict.get(state.counts, ip) |> result.unwrap(0)
  state.max_per_ip > 0
  && current >= state.max_per_ip
  || state.max_total > 0
  && state.total >= state.max_total
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

fn reclaim_cancelled_holders(state: State) -> State {
  // A releasing caller can die after cancelling, before sending Release.
  dict.fold(state.reservations, state, fn(state, reservation, holder) {
    case reservation_token_active(holder.token) {
      True -> state
      False -> release_reservation(state, reservation)
    }
  })
}

fn persist_cancelled_holders(state: State) -> Result(State, CheckpointError) {
  let recovered = reclaim_cancelled_holders(state)
  case recovered.total == state.total {
    True -> Ok(recovered)
    False -> persist(recovered)
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
  manager: Subject(CheckpointMessage),
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
    use #(table, origin, manager_owner) <- result.try(
      receive_checkpoint(manager) |> result.map_error(checkpoint_error_message),
    )
    let state =
      State(
        inbox: inbox,
        draining: False,
        checkpoint: table,
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
    use state <- result.try(
      open_state(state, origin) |> result.map_error(checkpoint_error_message),
    )
    use state <- result.try(
      State(..state, inbox: inbox, draining: False)
      |> recover_holders
      |> persist
      |> result.map_error(checkpoint_error_message),
    )
    use _ <- result.try(
      heirloom.set_heir(table, manager_owner, True)
      |> result.map_error(fn(error) {
        checkpoint_error_message(CheckpointHeirFailed(error))
      }),
    )
    schedule_sweep(subject, rate_config)
    schedule_queue_recovery(subject)
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
  manager: Subject(CheckpointMessage),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  build(
    max_per_ip,
    max_total,
    connection_rate,
    connection_burst,
    queue_limits,
    name,
    manager,
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
fn bind(permit: Permit, after_cancel: fn() -> Nil) -> Result(Nil, Nil) {
  let outcome = bind_request(permit)
  case outcome {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> {
      release_with_cancel_hook(permit, after_cancel)
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
  bind_optional_with_cancel_hook(permit, fn() { Nil })
}

/// Test seam for interruption after failed-bind cancellation, before notification.
@internal
pub fn bind_optional_with_cancel_hook(
  permit: Option(Permit),
  after_cancel: fn() -> Nil,
) -> Result(Nil, Nil) {
  case permit {
    Some(permit) -> bind(permit, after_cancel)
    None -> Ok(Nil)
  }
}

@external(erlang, "beryl_ffi", "pin_subject")
fn pin_subject(
  subject: Subject(message),
) -> Result(#(Subject(message), Pid), Nil)

/// Test seam for interruption after release cancellation, before notification.
@internal
pub fn release_with_cancel_hook(
  permit: Permit,
  after_cancel: fn() -> Nil,
) -> Nil {
  use <- bool.guard(when: !cancel_reservation_token(permit.token), return: Nil)
  after_cancel()
  // Cancel before resolving the owner so live and restart recovery can reclaim it.
  case pin_subject(permit.limiter.subject) {
    Ok(#(subject, _owner)) -> process.send(subject, Release(permit.reservation))
    Error(Nil) -> Nil
  }
}

/// Release a slot if one was acquired.
pub fn release_optional(permit: Option(Permit)) -> Nil {
  case permit {
    Some(permit) -> release_with_cancel_hook(permit, fn() { Nil })
    None -> Nil
  }
}
