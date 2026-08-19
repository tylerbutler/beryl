//// Runtime actor for supervised app-side dispatch systems.
////
//// One runtime actor serves every socket started through
//// `beryl.child_spec`. It is generic over the app's `model` and `msg`
//// types: per-socket models live in the actor state, typed `Info`
//// messages arrive through the actor's own mailbox, and no value is ever
//// type-erased. Transports reach the runtime through monomorphic closures
//// captured by `beryl.child_spec`, so the frame-level transport SPI stays
//// unparameterized.
////
//// The runtime owns inbound decoding and validation, rate limiting,
//// heartbeat eviction, topic subscriptions, and broadcast fan-out. It
//// also interprets effects: each `update` returns a list of `Effect`s that
//// are applied strictly in order within a single actor turn, so effect
//// list order is wire order.

import beryl/internal
import beryl/log.{type Logger}
import beryl/presence
import beryl/presence/wire as presence_wire
import beryl/pubsub.{type PubSub}
import beryl/rate_limit.{type RateLimitConfig}
import beryl/socket.{
  type ConnectInfo, type ConnectSeed, type Effect, type Input, type JoinRef,
  type Next, type ReplyRef, type StopReason,
} as sock
import beryl/telemetry
import beryl/topic.{type TopicPattern}
import beryl/wire/codec.{type Codec}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// Configuration for the runtime actor. Built by `beryl.child_spec` from a
/// `beryl.Config`; the fields cover per-topic-pattern rate limits.
pub type Config {
  Config(
    codec: Codec,
    heartbeat_timeout_ms: Int,
    message_limits: Option(RateLimitConfig),
    join_limits: Option(RateLimitConfig),
    channel_limits: Option(RateLimitConfig),
    channel_limiter_max_keys_per_socket: Int,
    /// Per-topic-pattern message rate limits. The first matching pattern
    /// wins; `None` disables limiting for a matching pattern, while topics
    /// matching no pattern fall back to `channel_limits`.
    topic_rates: List(#(TopicPattern, Option(RateLimitConfig))),
    max_topic_length: Int,
    max_event_length: Int,
    max_joined_topics_per_socket: Int,
    telemetry: Bool,
    logging: internal.LoggingConfig,
    presence: Option(presence.Presence),
    /// How long a socket may wait for a presence mutation to be
    /// acknowledged before the runtime gives up on it, logs, and resumes
    /// the rest of its effects. Bounds the suspension the same way the
    /// previous blocking `process.call` bounded the actor turn.
    presence_op_timeout_ms: Int,
  )
}

pub type AdmissionToken

@external(erlang, "beryl_ffi", "admission_token_new")
pub fn new_admission_token() -> AdmissionToken

@external(erlang, "beryl_ffi", "admission_token_cancel")
pub fn cancel_admission(token: AdmissionToken) -> Bool

@external(erlang, "beryl_ffi", "admission_token_pending")
fn admission_pending(token: AdmissionToken) -> Bool

@external(erlang, "beryl_ffi", "admission_token_claim")
fn claim_admission(token: AdmissionToken) -> Bool

fn admission_is_pending(admission: Option(AdmissionToken)) -> Bool {
  case admission {
    Some(token) -> admission_pending(token)
    None -> True
  }
}

fn claim_pending_admission(admission: Option(AdmissionToken)) -> Bool {
  case admission {
    Some(token) -> claim_admission(token)
    None -> True
  }
}

/// Messages the runtime actor handles.
pub type Msg(msg) {
  AdmitSocket(
    owner: process.Pid,
    socket_id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    codec: Option(Codec),
    seed: ConnectSeed,
    close: fn() -> Nil,
    admission: AdmissionToken,
    reply: Subject(Bool),
    /// The socket's actor, started by the transport's connection process
    /// so connection setup never serialises through the router. The router
    /// admits it atomically (monitor, index, forward) and the actor runs
    /// the app `init` and answers `reply` itself.
    actor: Subject(Msg(msg)),
    actor_pid: process.Pid,
  )
  SocketDisconnected(socket_id: String)
  RouteText(socket_id: String, raw_text: String)
  RouteDecoded(socket_id: String, msg: codec.Inbound)
  RouteDecodedBinary(socket_id: String, msg: codec.Inbound)
  HandleBinary(socket_id: String, data: BitArray)
  /// A typed server-side message for one socket, sent through its
  /// `Sender`. Delivered to `update` as `Info(message)`.
  AppInfo(socket_id: String, message: msg)
  /// Broadcast fan-out: local subscribers plus PubSub forwarding to other
  /// runtimes when PubSub is configured.
  Broadcast(topic: String, event: String, payload: Json, except: Option(String))
  RemoteBroadcast(pubsub.Message(Json))
  CheckHeartbeats
  GetStats(reply: Subject(StatsSnapshot))
  /// A presence mutation this runtime started has been applied (CRDT and
  /// read model both updated). Routed back to the socket waiting on it.
  PresenceAcknowledged(ack: presence.MutationAck)
  /// A presence mutation was not acknowledged in time. Ignored unless the
  /// socket is still waiting on exactly that operation.
  PresenceOpTimedOut(socket_id: String, op_id: Int)
  Stop(reply: Subject(Nil))
  /// Prototype (#334): a socket actor joined a topic. The router owns the
  /// global index and the pg subscription.
  IndexJoin(socket_id: String, topic: String)
  /// Prototype (#334): a socket actor left a topic.
  IndexLeave(socket_id: String, topic: String)
  /// Prototype (#334): a socket actor finished its teardown and is about to
  /// stop; the router drops it from the index and the actor table.
  SocketClosed(socket_id: String)
  /// Prototype (#334): the router died. Decision 5 wants router death to
  /// take every socket actor with it; the prototype monitors rather than
  /// supervises.
  RouterDown
  /// Prototype (#334): shut one socket actor down. Unlike `Stop` there is
  /// no reply — the router waits for `SocketClosed`, so a socket actor's
  /// teardown broadcasts still reach the router on their way out.
  StopSocketActor
  /// Prototype (#334): a socket actor never reported back during shutdown
  /// (it crashed, or its teardown hung). The router stops anyway.
  StopTimedOut
  /// Prototype (#334): shutdown phase one. Finalize in-flight presence work
  /// while every other socket actor is still alive to receive the leaves it
  /// publishes; the shared runtime got this for free by doing it before its
  /// teardown loop.
  FinalizeForStop
  /// Prototype (#334): a socket actor finished shutdown phase one.
  StopPhaseDone(socket_id: String)
}

pub type StatsSnapshot {
  StatsSnapshot(
    connected_sockets: Int,
    joined_socket_topic_pairs: Int,
    active_topics: Int,
  )
}

/// Erlang monotonic time in milliseconds
@external(erlang, "beryl_ffi", "monotonic_time_ms")
fn monotonic_time_ms() -> Int

type State(model, msg) {
  State(
    sockets: Dict(String, SocketState(model, msg)),
    /// Topic -> set of subscribed socket ids.
    topics: Dict(String, Set(String)),
    config: Config,
    pubsub: Option(PubSub(Json)),
    /// Typed PubSub subscription owned by this runtime actor, present
    /// whenever `pubsub` is. Joins/leaves topics and folds broadcast
    /// delivery into the actor's selector.
    subscriber: Option(pubsub.Subscriber(Json)),
    logger: Logger,
    self_subject: Subject(Msg(msg)),
    init: fn(ConnectInfo(msg)) -> #(model, List(Effect)),
    update: fn(model, Input(msg)) -> Next(model),
    message_buckets: Dict(String, rate_limit.Bucket),
    join_buckets: Dict(String, rate_limit.Bucket),
    channel_buckets: Dict(String, Dict(String, rate_limit.Bucket)),
    /// Reply target for asynchronous presence mutations, folded into the
    /// actor's selector as `PresenceAcknowledged`.
    presence_ack: Subject(presence.MutationAck),
    /// Source of presence operation ids. Monotonic, so an acknowledgement
    /// for an abandoned operation can never be mistaken for a newer one.
    next_op_id: Int,
    /// Sockets whose effect list is parked on a presence mutation, with
    /// the work to resume once it is acknowledged. Only these sockets are
    /// suspended: every other socket, broadcast, and system message keeps
    /// being processed.
    suspended: Dict(String, Suspension(msg)),
    /// Socket-scoped messages that arrived while their socket was
    /// suspended, newest first. Delivered in arrival order once the socket
    /// resumes.
    queued: Dict(String, List(Msg(msg))),
    /// How many tracks per socket the runtime gave up on (timed out) while
    /// their acknowledgement could still arrive — the entries whose refs
    /// this runtime does not know and only learns from the late
    /// acknowledgement it compensates. Decremented as each one is
    /// compensated, and swept wholesale at shutdown, when no
    /// acknowledgement can be received any more.
    unacked_tracks: Dict(String, Int),
    /// Set while the runtime is draining for shutdown. Presence mutations
    /// are then fire-and-forget: there is no longer a runtime to deliver
    /// the acknowledgement to.
    stopping: Bool,
    /// Prototype (#334): `None` in the router, `Some(router)` in a
    /// per-socket actor. Every socket-scoped function below is lifted
    /// unchanged by handing the socket actor this same `State` with exactly
    /// one entry in `sockets`; this field is what the handful of
    /// router-owned operations (fan-out, topic index, PubSub) branch on.
    router: Option(Subject(Msg(msg))),
    /// Prototype (#334): router-only. socket_id -> its socket actor.
    socket_actors: Dict(String, Subject(Msg(msg))),
    /// Prototype (#334): router-only. Set while the router is draining its
    /// socket actors; answered once the last `SocketClosed` arrives.
    stop_reply: Option(Subject(Nil)),
    /// Prototype (#334): router-only. How many socket actors have finished
    /// shutdown phase one. Teardown starts when every one of them has.
    stop_finalized: Int,
  )
}

// ── Suspended per-socket work ───────────────────────────────────────────────
//
// Presence mutations are asynchronous, but an effect list must still be
// applied strictly in order and a topic close must still finish its cleanup
// before its terminal frame. So the work a socket has left to do is reified
// as a stack of `Step`s: the interpreter runs steps until the stack is
// empty or a step needs a presence acknowledgement, at which point the
// remaining stack is parked in `State.suspended` and resumed verbatim when
// the acknowledgement (or the timeout) arrives. Nothing about the other
// sockets, broadcasts, or heartbeats is parked with it.

/// A socket parked on one in-flight presence mutation.
type Suspension(msg) {
  Suspension(
    op_id: Int,
    op: PresenceOp,
    /// Cancelled when the acknowledgement arrives in time.
    timer: process.Timer,
    /// Work to resume, in order, after the mutation is applied.
    stack: List(Step(msg)),
  )
}

/// The presence mutation a socket is waiting for, and everything needed to
/// finish it once it is acknowledged (or given up on).
type PresenceOp {
  /// A `PresenceTrack`. The ref and stored meta only exist once the actor
  /// replies, so both the socket's ref map and the join diff are written
  /// from the acknowledgement. `replaced` is the previous entry for the
  /// same key, broadcast as the leave half of the replacement.
  TrackOp(topic: String, key: String, replaced: List(presence.PresenceEntry))
  /// A `PresenceUntrack` (`automatic: False`) or the automatic cleanup of
  /// a closing topic (`automatic: True`). The leaves are already known
  /// from the runtime's own ref map; only the broadcast waits.
  UntrackOp(
    topic: String,
    leaves: List(presence.PresenceEntry),
    automatic: Bool,
  )
}

/// One resumable unit of per-socket work.
type Step(msg) {
  /// Apply the remaining effects of one update's effect list.
  StepEffects(
    effects: List(Effect),
    pending: Option(Pending),
    kicks: List(String),
    cont: Cont,
  )
  /// Deliver one input to the app's `update` and apply what it returns.
  StepInput(input: Input(msg), source: Source, cont: Cont)
  /// Deliver a join that was waiting for a duplicate topic to close.
  StepDeliverJoin(
    topic: String,
    payload: Dynamic,
    join_ref: Option(String),
    ref: Option(String),
    started_at: Int,
  )
  /// Fan an undecodable binary frame out to the remaining joined topics.
  StepBinaryTopics(topics: List(String), data: BitArray, started_at: Int)
  /// Begin closing one joined topic.
  StepCloseTopic(topic: String, reason: StopReason, cont: Cont)
  /// Auto-untrack whatever presence the closing topic still holds.
  StepCloseCleanup(
    topic: String,
    close_join_ref: Option(String),
    reason: StopReason,
    kicks: List(String),
    stop: Option(StopReason),
    cont: Cont,
  )
  /// Send the closing topic's terminal frame, then hand its outcome on.
  StepCloseFinish(
    topic: String,
    close_join_ref: Option(String),
    reason: StopReason,
    kicks: List(String),
    stop: Option(StopReason),
    cont: Cont,
  )
  /// Follow-ups from an update: tear the socket down, or close its kicked
  /// topics one at a time.
  StepDrive(kicks: List(String), stop: Option(StopReason))
  /// Begin tearing the socket down.
  StepTeardown(reason: StopReason)
  /// Close a teardown's remaining topics, in order.
  StepTeardownTopics(topics: List(String), reason: StopReason)
  /// Drop rate limits, close the transport, and forget the socket.
  StepTeardownFinish(
    reason: StopReason,
    connected_at: Int,
    joined_channels: Int,
  )
  /// Emit callback telemetry after every effect, including asynchronous
  /// presence work, has reached its ordered position.
  StepFinishUpdate(source: Source, effects: List(Effect))
}

/// What to do with the kicks and stop an effect list or topic close
/// produced. This is the reified "return address" of a step.
type Cont {
  /// Drive them as ordinary update follow-ups.
  ContDrive
  /// Append them to a kick queue already in progress, then drive.
  ContKicks(rest: List(String))
  /// Continue the enclosing topic close: cleanup, then terminal frame.
  ContCloseTopic(
    topic: String,
    close_join_ref: Option(String),
    reason: StopReason,
    outer: Cont,
  )
  /// Discard them (a teardown is already in progress) and close the next
  /// topic of that teardown.
  ContTeardownTopics(topics: List(String), reason: StopReason)
  /// Emit an update's terminal telemetry before continuing its caller.
  ContFinishUpdate(source: Source, effects: List(Effect), outer: Cont)
}

/// The result of executing one step.
type Exec(model, msg) {
  /// Continue immediately with `steps` pushed onto the stack.
  Continue(state: State(model, msg), steps: List(Step(msg)))
  /// Park the socket until the presence mutation identified by `op_id` is
  /// acknowledged, then resume with `steps` pushed onto the stack.
  Await(
    state: State(model, msg),
    op_id: Int,
    op: PresenceOp,
    timer: process.Timer,
    steps: List(Step(msg)),
  )
}

type SocketState(model, msg) {
  SocketState(
    id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    close: fn() -> Nil,
    codec: Codec,
    /// The app's per-socket model, threaded through `update`.
    model: model,
    subscribed_topics: Set(String),
    /// Per-topic join_ref from the accepted join, echoed in replies and
    /// terminal frames and used to drop stale-instance messages.
    join_refs: Dict(String, Option(String)),
    /// Presence refs tracked through socket effects, grouped by topic and key.
    presence_refs: Dict(String, Dict(String, #(String, Json))),
    /// Message reply refs still awaiting a reply. A ref is added when its
    /// `Message` is delivered, removed when answered (so a reply is
    /// single-use), and pruned when its topic closes (so a stale ref stored
    /// across a leave/rejoin is not replied to).
    pending_reply_refs: Set(ReplyRef),
    last_heartbeat: Int,
    /// Native monotonic timestamp captured when the socket was accepted.
    connected_at: Int,
  )
}

/// A join delivered to `update` that has not been answered yet.
type Pending {
  Pending(
    topic: String,
    join_ref: Option(String),
    msg_ref: Option(String),
    ref: JoinRef,
  )
}

/// Where an event delivered to `update` came from, for crash attribution.
type Source {
  JoinSource(
    topic: String,
    join_ref: Option(String),
    msg_ref: Option(String),
    ref: JoinRef,
    started_at: Int,
  )
  MessageSource(topic: String, kind: telemetry.MessageKind, started_at: Int)
  InfoSource(started_at: Int)
  ClosedSource
}

/// Start runtime telemetry without touching the VM clock when disabled.
fn telemetry_start(state: State(model, msg)) -> Int {
  use <- bool.guard(when: !state.config.telemetry, return: 0)
  telemetry.start_time()
}

fn emit_join_stop(
  state: State(model, msg),
  started_at: Int,
  outcome: telemetry.JoinOutcome,
) -> Nil {
  use <- bool.guard(when: !state.config.telemetry, return: Nil)
  telemetry.emit(
    True,
    telemetry.ChannelJoinStop(
      duration: telemetry.duration_since(started_at),
      outcome: outcome,
    ),
  )
}

fn emit_message_stop(
  state: State(model, msg),
  started_at: Int,
  kind: telemetry.MessageKind,
  outcome: telemetry.MessageOutcome,
  callback_result: telemetry.CallbackResult,
) -> Nil {
  use <- bool.guard(when: !state.config.telemetry, return: Nil)
  telemetry.emit(
    True,
    telemetry.ChannelMessageStop(
      duration: telemetry.duration_since(started_at),
      kind: kind,
      outcome: outcome,
      callback_result: callback_result,
    ),
  )
}

fn disconnect_reason_telemetry(
  reason: StopReason,
) -> telemetry.DisconnectReason {
  case reason {
    sock.Normal -> telemetry.NormalDisconnect
    sock.Shutdown -> telemetry.ShutdownDisconnect
    sock.HeartbeatTimeout -> telemetry.HeartbeatTimeout
    sock.Errored(_) -> telemetry.CallbackDisconnect
  }
}

/// Start the runtime actor registered under `name`.
///
/// There is deliberately no unsupervised start: `beryl.child_spec` runs
/// the runtime under a supervisor, and a crash restarts it with dispatch
/// intact because the `init`/`update` closures live in the child
/// specification. The registered name keeps transport and broadcast
/// handles valid across restarts (per-socket state is dropped on restart).
pub fn start_named(
  config: Config,
  name name: process.Name(Msg(msg)),
  pubsub pubsub_option: Option(PubSub(Json)),
  init init: fn(ConnectInfo(msg)) -> #(model, List(Effect)),
  update update: fn(model, Input(msg)) -> Next(model),
) -> Result(actor.Started(Subject(Msg(msg))), actor.StartError) {
  internal.configure(config.logging)

  actor.new_with_initialiser(5000, fn(subject) {
    // Presence acknowledgements arrive on their own subject (the presence
    // actor knows nothing about `Msg(msg)`) and are folded into the
    // actor's selector.
    let ack_subject = process.new_subject()
    let base =
      State(
        sockets: dict.new(),
        topics: dict.new(),
        config: config,
        pubsub: pubsub_option,
        subscriber: None,
        logger: internal.logger_with_config("beryl.runtime", config.logging),
        self_subject: subject,
        init: init,
        update: update,
        message_buckets: dict.new(),
        join_buckets: dict.new(),
        channel_buckets: dict.new(),
        presence_ack: ack_subject,
        next_op_id: 1,
        suspended: dict.new(),
        queued: dict.new(),
        unacked_tracks: dict.new(),
        stopping: False,
        router: None,
        socket_actors: dict.new(),
        stop_reply: None,
        stop_finalized: 0,
      )
    // Prototype (#334): heartbeats are per-socket timers now (phasing step
    // 3), so the router runs no sweep and schedules nothing.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(ack_subject, PresenceAcknowledged)
    case pubsub_option {
      Some(pubsub_instance) -> {
        let subscriber = pubsub.subscriber(pubsub_instance)
        let state = State(..base, subscriber: Some(subscriber))
        actor.initialised(state)
        |> actor.returning(subject)
        |> actor.selecting(pubsub.selecting(
          selector,
          subscriber,
          RemoteBroadcast,
        ))
        |> Ok
      }
      None ->
        actor.initialised(base)
        |> actor.returning(subject)
        |> actor.selecting(selector)
        |> Ok
    }
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

/// Start one actor to own one socket.
///
/// It runs the same `handle_message` on the same `State` as the router —
/// the socket actor is the router with `sockets` capped at one entry, no
/// topic index beyond its own memberships, no PubSub subscriber, and
/// `router` set. That is the whole lift of `dispatch_socket_msg`.
///
/// Called from the transport's connection process (via `beryl`'s admission
/// closure), not from the router, so connection setup stays parallel and
/// the router's admission turn stays O(1). The caller is expected to
/// unlink the started actor and hand it to the router with `AdmitSocket`.
pub fn start_socket_actor(
  config config: Config,
  init init: fn(ConnectInfo(msg)) -> #(model, List(Effect)),
  update update: fn(model, Input(msg)) -> Next(model),
  router router: Subject(Msg(msg)),
  router_pid router_pid: process.Pid,
) -> Result(actor.Started(Subject(Msg(msg))), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    let ack_subject = process.new_subject()
    let state =
      State(
        sockets: dict.new(),
        topics: dict.new(),
        config: config,
        pubsub: None,
        subscriber: None,
        logger: internal.logger_with_config("beryl.runtime", config.logging),
        self_subject: subject,
        init: init,
        update: update,
        message_buckets: dict.new(),
        join_buckets: dict.new(),
        channel_buckets: dict.new(),
        presence_ack: ack_subject,
        next_op_id: 1,
        suspended: dict.new(),
        queued: dict.new(),
        unacked_tracks: dict.new(),
        stopping: False,
        router: Some(router),
        socket_actors: dict.new(),
        stop_reply: None,
        stop_finalized: 0,
      )
    // Router death must take its socket actors with it: each actor
    // monitors the router and stops on its `Down`, while staying unlinked
    // so a socket crash cannot travel the other way.
    let monitor = process.monitor(router_pid)
    schedule_heartbeat_check(subject, config)
    process.new_selector()
    |> process.select(subject)
    |> process.select_map(ack_subject, PresenceAcknowledged)
    |> process.select_specific_monitor(monitor, fn(_) { RouterDown })
    |> actor.selecting(actor.returning(actor.initialised(state), subject), _)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Check at half the staleness window; `beryl.validate_config` guarantees the
/// timeout is at least 2, so the interval is always positive.
fn schedule_heartbeat_check(subject: Subject(Msg(msg)), config: Config) -> Nil {
  let _timer =
    process.send_after(
      subject,
      config.heartbeat_timeout_ms / 2,
      CheckHeartbeats,
    )
  Nil
}

fn handle_message(
  state: State(model, msg),
  message: Msg(msg),
) -> actor.Next(State(model, msg), Msg(msg)) {
  case message {
    AdmitSocket(
      owner,
      socket_id,
      send,
      send_binary,
      socket_codec,
      seed,
      close,
      admission,
      reply,
      actor_subject,
      actor_pid,
    ) ->
      handle_admit_socket(
        state,
        owner,
        socket_id,
        send,
        send_binary,
        socket_codec,
        seed,
        close,
        admission,
        reply,
        actor_subject,
        actor_pid,
      )
    // Socket-scoped work. A socket parked on a presence acknowledgement
    // queues its own messages instead of dispatching them, so its inbound
    // order survives the suspension; every other socket is unaffected.
    SocketDisconnected(socket_id)
    | RouteText(socket_id, _)
    | RouteDecoded(socket_id, _)
    | RouteDecodedBinary(socket_id, _)
    | HandleBinary(socket_id, _)
    | AppInfo(socket_id, _) ->
      case state.router {
        // ponytail: the router forwards every inbound message to the
        // socket's actor, so it stays on the inbound path for one send per
        // message. Ceiling: router throughput is still O(messages), though
        // its turn is now a match-and-send instead of an app callback.
        // Upgrade: hand the socket actor's subject back to the transport at
        // admission (or keep a registry) so transports send direct.
        None -> {
          case dict.get(state.socket_actors, socket_id) {
            Ok(socket_actor) -> process.send(socket_actor, message)
            Error(Nil) -> Nil
          }
          actor.continue(state)
        }
        Some(_) ->
          case dict.has_key(state.suspended, socket_id) {
            True ->
              actor.continue(enqueue_socket_msg(state, socket_id, message))
            False ->
              after_socket_turn(state, dispatch_socket_msg(state, message))
          }
      }
    Broadcast(topic_name, event_name, payload, except) -> {
      case state.router {
        // In a socket actor this is a delivery, not an origination: the
        // router already resolved the recipients (decision 1's hop) and
        // this actor encodes and sends for its own socket.
        Some(_) -> {
          let _counts =
            local_broadcast(state, topic_name, event_name, payload, except)
          Nil
        }
        None ->
          broadcast_with_pubsub(state, topic_name, event_name, payload, except)
      }
      actor.continue(state)
    }
    RemoteBroadcast(pubsub_msg) ->
      // Crash boundary — see internal.rescue. The payload's own shape is a
      // frozen wire contract; drop malformed frames from mismatched peers.
      case
        internal.rescue(fn() { handle_remote_broadcast(state, pubsub_msg) })
      {
        Ok(next) -> actor.continue(next)
        Error(crash) -> {
          state.logger
          |> log.error("Remote broadcast dropped: malformed message", [
            #("crash", crash),
          ])
          actor.continue(state)
        }
      }
    CheckHeartbeats -> actor.continue(handle_check_heartbeats(state))
    PresenceAcknowledged(ack) ->
      after_socket_turn(state, handle_presence_ack(state, ack))
    PresenceOpTimedOut(socket_id, op_id) ->
      after_socket_turn(state, handle_presence_timeout(state, socket_id, op_id))
    GetStats(reply) -> {
      // Answered entirely from the router's index; no socket actor is
      // polled, so counts may lag in-flight socket lifecycle messages —
      // the eventual consistency the stats API documents.
      process.send(
        reply,
        StatsSnapshot(
          connected_sockets: dict.size(state.socket_actors),
          joined_socket_topic_pairs: state.topics
            |> dict.values
            |> list.fold(0, fn(total, ids) { total + set.size(ids) }),
          active_topics: dict.size(state.topics),
        ),
      )
      actor.continue(state)
    }
    Stop(reply) ->
      case state.router {
        Some(_) -> handle_stop(state, Some(reply))
        None -> begin_router_stop(state, reply)
      }
    FinalizeForStop -> {
      let state = finalize_for_stop(state)
      case state.router, dict.keys(state.sockets) {
        Some(router), [socket_id] ->
          process.send(router, StopPhaseDone(socket_id))
        // No socket ever registered here; report under a name the router
        // does not need, since it only counts.
        Some(router), _ -> process.send(router, StopPhaseDone(""))
        None, _ -> Nil
      }
      actor.continue(state)
    }
    StopPhaseDone(_) -> {
      let state = State(..state, stop_finalized: state.stop_finalized + 1)
      case state.stop_finalized >= dict.size(state.socket_actors) {
        True ->
          dict.values(state.socket_actors)
          |> list.each(process.send(_, StopSocketActor))
        False -> Nil
      }
      actor.continue(state)
    }
    StopSocketActor -> {
      // The router is waiting on `SocketClosed`, not on a reply, so the
      // teardown's own broadcasts reach it before the actor goes away.
      let socket_ids = dict.keys(state.sockets)
      let next = handle_stop(state, None)
      case state.router, socket_ids {
        Some(router), [socket_id] ->
          process.send(router, SocketClosed(socket_id))
        _, _ -> Nil
      }
      next
    }
    StopTimedOut ->
      case state.stop_reply {
        None -> actor.continue(state)
        Some(reply) -> {
          state.logger
          |> log.warn("Runtime stop: socket actors did not all report back", [
            #("socket_count", int.to_string(dict.size(state.socket_actors))),
          ])
          process.send(reply, Nil)
          actor.stop()
        }
      }
    IndexJoin(socket_id, topic_name) ->
      actor.continue(add_topic_subscriber(state, socket_id, topic_name))
    IndexLeave(socket_id, topic_name) ->
      actor.continue(remove_topic_subscriber(state, socket_id, topic_name))
    SocketClosed(socket_id) -> {
      // A teardown emits `IndexLeave` per joined topic, but sweeping is
      // cheap and makes a dropped one impossible to leak.
      let state =
        dict.keys(state.topics)
        |> list.fold(state, fn(st, topic_name) {
          remove_topic_subscriber(st, socket_id, topic_name)
        })
      let state =
        State(
          ..state,
          socket_actors: dict.delete(state.socket_actors, socket_id),
        )
      case state.stop_reply, dict.is_empty(state.socket_actors) {
        Some(reply), True -> {
          process.send(reply, Nil)
          actor.stop()
        }
        _, _ -> actor.continue(state)
      }
    }
    RouterDown -> actor.stop()
  }
}

/// Prototype (#334): a socket actor's turn is over. If the socket is gone
/// the actor has nothing left to own, so it tells the router and stops.
fn after_socket_turn(
  before: State(model, msg),
  after: State(model, msg),
) -> actor.Next(State(model, msg), Msg(msg)) {
  case dict.keys(before.sockets), after.router {
    [socket_id], Some(router) ->
      case dict.has_key(after.sockets, socket_id) {
        True -> actor.continue(after)
        False -> {
          process.send(router, SocketClosed(socket_id))
          actor.stop()
        }
      }
    _, _ -> actor.continue(after)
  }
}

/// Dispatch one socket-scoped message. Called directly when the socket is
/// running and from `drain_queue` for messages that arrived while it was
/// suspended, so both paths share exactly one implementation.
fn dispatch_socket_msg(
  state: State(model, msg),
  message: Msg(msg),
) -> State(model, msg) {
  case message {
    SocketDisconnected(socket_id) ->
      handle_socket_disconnected(state, socket_id)
    RouteText(socket_id, raw_text) ->
      handle_route_text(state, socket_id, raw_text)
    RouteDecoded(socket_id, msg) ->
      dispatch_inbound(state, socket_id, msg, telemetry.TextMessage)
    RouteDecodedBinary(socket_id, msg) ->
      dispatch_inbound(state, socket_id, msg, telemetry.BinaryMessage)
    HandleBinary(socket_id, data) -> handle_binary_in(state, socket_id, data)
    AppInfo(socket_id, app_message) ->
      handle_app_info(state, socket_id, app_message)
    // Not socket-scoped, so never deferred to this dispatcher.
    AdmitSocket(..)
    | Broadcast(..)
    | RemoteBroadcast(..)
    | CheckHeartbeats
    | GetStats(..)
    | PresenceAcknowledged(..)
    | PresenceOpTimedOut(..)
    | Stop(..)
    | StopSocketActor
    | StopTimedOut
    | FinalizeForStop
    | StopPhaseDone(..)
    | IndexJoin(..)
    | IndexLeave(..)
    | SocketClosed(..)
    | RouterDown -> state
  }
}

/// Defer a socket-scoped message until its socket resumes. The queue is
/// stored newest-first and reversed once per drain, so queueing stays O(1)
/// per message even under a flood.
fn enqueue_socket_msg(
  state: State(model, msg),
  socket_id: String,
  message: Msg(msg),
) -> State(model, msg) {
  let queue =
    dict.get(state.queued, socket_id)
    |> result.unwrap([])
  state.logger
  |> log.debug("Socket message queued: presence mutation in flight", [
    #("socket_id", socket_id),
  ])
  State(
    ..state,
    queued: dict.insert(state.queued, socket_id, [message, ..queue]),
  )
}

/// Deliver everything queued for a socket, in arrival order, stopping if
/// another presence mutation suspends it again.
fn drain_queue(
  state: State(model, msg),
  socket_id: String,
) -> State(model, msg) {
  // Resuming one mutation can immediately park the socket on the next one;
  // its queue then has to keep waiting rather than jump the suspension.
  use <- bool.guard(
    when: dict.has_key(state.suspended, socket_id),
    return: state,
  )
  case dict.get(state.queued, socket_id) {
    Error(Nil) -> state
    Ok(queue) ->
      drain_messages(
        State(..state, queued: dict.delete(state.queued, socket_id)),
        socket_id,
        list.reverse(queue),
      )
  }
}

fn drain_messages(
  state: State(model, msg),
  socket_id: String,
  messages: List(Msg(msg)),
) -> State(model, msg) {
  case messages {
    [] -> state
    [message, ..rest] -> {
      let state = dispatch_socket_msg(state, message)
      case dict.has_key(state.suspended, socket_id) {
        True ->
          State(
            ..state,
            queued: dict.insert(state.queued, socket_id, list.reverse(rest)),
          )
        False -> drain_messages(state, socket_id, rest)
      }
    }
  }
}

// ── Socket lifecycle ────────────────────────────────────────────────────────

fn handle_admit_socket(
  state: State(model, msg),
  owner: process.Pid,
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  socket_codec: Option(Codec),
  seed: ConnectSeed,
  close: fn() -> Nil,
  admission: AdmissionToken,
  reply: Subject(Bool),
  actor_subject: Subject(Msg(msg)),
  actor_pid: process.Pid,
) -> actor.Next(State(model, msg), Msg(msg)) {
  case state.router {
    // In a socket actor: the router has already admitted this socket
    // atomically in its own turn; this actor runs the app `init` and
    // answers the transport directly.
    Some(router) -> {
      let #(state, admitted) =
        register_socket(
          state,
          socket_id,
          send,
          send_binary,
          socket_codec,
          seed,
          close,
          Some(admission),
        )
      process.send(reply, admitted)
      case admitted {
        True -> actor.continue(state)
        // Refused: the app `init` crashed, or the transport's wait timed
        // out and cancelled the token. The router already indexed this
        // actor, so unwind that entry on the way out.
        False -> {
          process.send(router, SocketClosed(socket_id))
          actor.stop()
        }
      }
    }
    // The router's whole admission turn: the checks that must be atomic
    // with each other, one monitor-free insert, and a forward. It never
    // waits on the socket actor — the actor answers the transport itself,
    // so a slow or crashing `init` cannot block admission of other
    // sockets (and the router must never block on a socket actor).
    None ->
      case
        !state.stopping
        && process.self() == owner
        && admission_pending(admission)
      {
        False -> {
          process.send(reply, False)
          actor.continue(state)
        }
        True -> {
          process.send(
            actor_subject,
            AdmitSocket(
              owner,
              socket_id,
              send,
              send_binary,
              socket_codec,
              seed,
              close,
              admission,
              reply,
              actor_subject,
              actor_pid,
            ),
          )
          actor.continue(
            State(
              ..state,
              socket_actors: dict.insert(
                state.socket_actors,
                socket_id,
                actor_subject,
              ),
            ),
          )
        }
      }
  }
}

fn register_socket(
  state: State(model, msg),
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  socket_codec: Option(Codec),
  seed: ConnectSeed,
  close: fn() -> Nil,
  admission: Option(AdmissionToken),
) -> #(State(model, msg), Bool) {
  use <- bool.guard(when: !admission_is_pending(admission), return: #(
    state,
    False,
  ))
  let sender = make_socket_sender(state, socket_id)
  let info = sock.ConnectInfo(socket_id: socket_id, seed: seed, self: sender)
  let init = state.init
  // Crash boundary — see internal.rescue. A failed init never registers.
  case internal.rescue(fn() { init(info) }) {
    Error(crash) -> {
      state.logger
      |> log.error("Socket init crashed; socket not registered", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      #(state, False)
    }
    Ok(#(model, effects)) -> {
      use <- bool.guard(when: !claim_pending_admission(admission), return: #(
        state,
        False,
      ))
      let socket =
        SocketState(
          id: socket_id,
          send: send,
          send_binary: send_binary,
          close: close,
          codec: option.unwrap(socket_codec, state.config.codec),
          model: model,
          subscribed_topics: set.new(),
          join_refs: dict.new(),
          presence_refs: dict.new(),
          pending_reply_refs: set.new(),
          last_heartbeat: monotonic_time_ms(),
          connected_at: telemetry_start(state),
        )
      state.logger |> log.info("Socket connected", [#("socket_id", socket_id)])
      let state =
        State(..state, sockets: dict.insert(state.sockets, socket_id, socket))
      telemetry.emit(state.config.telemetry, telemetry.SocketConnected)
      // Nothing is joined yet, so kicks cannot arise and pushes to
      // unjoined topics are dropped by the interpreter.
      #(run_effects_from(state, socket_id, effects), True)
    }
  }
}

/// Start an effect list for a socket from outside an update.
fn run_effects_from(
  state: State(model, msg),
  socket_id: String,
  effects: List(Effect),
) -> State(model, msg) {
  run(state, socket_id, [StepEffects(effects, None, [], ContDrive)])
}

/// Build the typed `Sender` for a socket. The closure sends through the
/// runtime's own mailbox — an ordinary typed send, usable from any process.
fn make_socket_sender(
  state: State(model, msg),
  socket_id: String,
) -> sock.Sender(msg) {
  let subject = state.self_subject
  sock.make_sender(fn(message) {
    process.send(subject, AppInfo(socket_id, message))
  })
}

fn handle_socket_disconnected(
  state: State(model, msg),
  socket_id: String,
) -> State(model, msg) {
  let metadata = case dict.get(state.sockets, socket_id) {
    Ok(socket) ->
      list.append([#("socket_id", socket_id)], joined_topics_metadata(socket))
    Error(Nil) -> [#("socket_id", socket_id)]
  }
  state.logger |> log.info("Socket disconnected", metadata)
  run(state, socket_id, [StepTeardown(sock.Normal)])
}

/// Prototype (#334): drain the socket actors, then stop.
///
/// The router casts `StopSocketActor` rather than calling, so a socket
/// actor's teardown broadcasts and index updates still route through this
/// mailbox. The router answers `reply` once the last `SocketClosed` lands.
///
/// ponytail: the fallback timeout is a hardcoded 2s, chosen only to sit
/// inside `beryl.stop`'s own 5s budget. Ceiling: a socket actor whose
/// teardown legitimately takes longer is abandoned. Upgrade: make it a
/// config knob, or monitor the socket actors instead of timing out.
fn begin_router_stop(
  state: State(model, msg),
  reply: Subject(Nil),
) -> actor.Next(State(model, msg), Msg(msg)) {
  state.logger
  |> log.info("Runtime stopping", [
    #("socket_count", int.to_string(dict.size(state.socket_actors))),
  ])
  use <- bool.lazy_guard(when: dict.is_empty(state.socket_actors), return: fn() {
    process.send(reply, Nil)
    actor.stop()
  })
  dict.values(state.socket_actors)
  |> list.each(process.send(_, FinalizeForStop))
  let _timer = process.send_after(state.self_subject, 2000, StopTimedOut)
  actor.continue(State(..state, stopping: True, stop_reply: Some(reply)))
}

fn handle_stop(
  state: State(model, msg),
  reply: Option(Subject(Nil)),
) -> actor.Next(State(model, msg), Msg(msg)) {
  state.logger
  |> log.info("Runtime stopping", [
    #("socket_count", int.to_string(dict.size(state.sockets))),
  ])
  let state = finalize_for_stop(state)
  dict.keys(state.sockets)
  |> list.fold(state, fn(st, socket_id) {
    run(st, socket_id, [StepTeardown(sock.Shutdown)])
  })
  case reply {
    Some(reply) -> process.send(reply, Nil)
    None -> Nil
  }
  actor.stop()
}

/// The pre-teardown half of a shutdown: mark the actor stopping and settle
/// every in-flight presence mutation it still owns.
///
/// Prototype (#334): the shared runtime ran this for all sockets before it
/// tore any of them down. Per-socket actors have to be told to do it as a
/// separate phase, or a socket's shutdown leaves can be fanned out to
/// sockets that are already gone.
fn finalize_for_stop(state: State(model, msg)) -> State(model, msg) {
  // From here on there is no runtime left to receive an acknowledgement,
  // so presence mutations are sent fire-and-forget and never suspend.
  let state = State(..state, stopping: True)
  let state =
    dict.keys(state.suspended)
    |> list.fold(state, finalize_suspension)
  // Tracks this runtime already gave up on can still be applied by the
  // presence actor, and their acknowledgements can no longer be
  // compensated once this actor stops — so their runtime-owned refs are
  // swept now, while there is still something to sweep them with. The sweep is
  // ordered behind the in-flight tracks themselves (same sender, same
  // mailbox), so it removes them rather than racing them.
  dict.keys(state.unacked_tracks)
  |> list.fold(state, sweep_unacked_track)
}

/// Finalize a socket's in-flight presence mutation during shutdown.
///
/// The runtime cannot wait for its acknowledgement, but it must still publish
/// the leave side of a pending replacement or untrack because those refs have
/// already left the socket's bookkeeping. The mutation is finalized through
/// the normal stopping path, then every runtime-owned ref for the socket is
/// swept behind the in-flight mutation in the presence actor's mailbox.
fn finalize_suspension(
  state: State(model, msg),
  socket_id: String,
) -> State(model, msg) {
  case dict.get(state.suspended, socket_id) {
    Error(Nil) -> state
    Ok(suspension) -> {
      let _cancelled = process.cancel_timer(suspension.timer)
      state.logger
      |> log.warn("Presence operation finalized: runtime stopping", [
        #("socket_id", socket_id),
      ])
      let state =
        State(
          ..state,
          suspended: dict.delete(state.suspended, socket_id),
          queued: dict.delete(state.queued, socket_id),
          // The runtime-owned sweep below also removes anything an earlier,
          // already-timed-out track of this socket could still add.
          unacked_tracks: dict.delete(state.unacked_tracks, socket_id),
        )
      let state =
        finish_presence_op(
          state,
          socket_id,
          suspension.op,
          Error(PresenceStopping),
        )
      case state.config.presence {
        Some(handle) -> presence.untrack_runtime_all_async(handle, socket_id)
        None -> Nil
      }
      state
    }
  }
}

/// Sweep a session whose earlier, timed-out track may still land at the
/// presence actor after this runtime is gone. Same reasoning as
/// `finalize_suspension`: the ref was never learned here, and after
/// shutdown never will be, so the session's runtime-owned refs are removed
/// instead of leaving an entry nothing can remove.
fn sweep_unacked_track(
  state: State(model, msg),
  socket_id: String,
) -> State(model, msg) {
  state.logger
  |> log.warn("Presence track abandoned: runtime stopping", [
    #("socket_id", socket_id),
  ])
  case state.config.presence {
    Some(handle) -> presence.untrack_runtime_all_async(handle, socket_id)
    None -> Nil
  }
  State(..state, unacked_tracks: dict.delete(state.unacked_tracks, socket_id))
}

// ── Heartbeats ──────────────────────────────────────────────────────────────

fn handle_heartbeat(
  state: State(model, msg),
  socket_id: String,
  ref: Option(String),
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> {
      let state =
        store_socket(
          state,
          SocketState(..socket, last_heartbeat: monotonic_time_ms()),
        )
      let reply = codec.encode_heartbeat_reply(socket.codec)(ref)
      let _send_result =
        send_frame_logged(state, socket, "__heartbeat__", reply)
      state.logger
      |> log.debug("Heartbeat handled", [
        #("socket_id", socket_id),
        #("ref", optional_string(ref)),
      ])
      state
    }
  }
}

fn handle_check_heartbeats(state: State(model, msg)) -> State(model, msg) {
  let now = monotonic_time_ms()
  let timeout_ms = state.config.heartbeat_timeout_ms
  let stale_socket_ids =
    state.sockets
    |> dict.filter(fn(socket_id, socket) {
      // A socket parked on a presence acknowledgement is skipped: evicting
      // it mid-continuation would strand that work. The suspension is
      // bounded by `presence_op_timeout_ms`, so it is evicted by a later
      // sweep instead.
      now - socket.last_heartbeat > timeout_ms
      && !dict.has_key(state.suspended, socket_id)
    })
    |> dict.keys
  list.each(stale_socket_ids, fn(socket_id) {
    state.logger
    |> log.warn("Evicting socket due to heartbeat timeout", [
      #("socket_id", socket_id),
      #("timeout_ms", int.to_string(timeout_ms)),
    ])
  })
  let state =
    list.fold(stale_socket_ids, state, fn(st, socket_id) {
      run(st, socket_id, [StepTeardown(sock.HeartbeatTimeout)])
    })
  schedule_heartbeat_check(state.self_subject, state.config)
  state
}

// ── Inbound decoding and dispatch ───────────────────────────────────────────

fn handle_route_text(
  state: State(model, msg),
  socket_id: String,
  raw_text: String,
) -> State(model, msg) {
  let active_codec = case dict.get(state.sockets, socket_id) {
    Ok(socket) -> socket.codec
    Error(Nil) -> state.config.codec
  }
  let logging = state.config.logging
  case codec.decode_text(active_codec)(raw_text) {
    Error(err) -> {
      state.logger
      |> log.warn(
        "Failed to decode wire protocol message",
        list.append(
          [
            #("socket_id", socket_id),
            #("error", codec.format_decode_error(err)),
          ],
          internal.preview_metadata("frame_preview", raw_text, logging),
        ),
      )
      state
    }
    Ok(msg) -> dispatch_inbound(state, socket_id, msg, telemetry.TextMessage)
  }
}

fn dispatch_inbound(
  state: State(model, msg),
  socket_id: String,
  msg: codec.Inbound,
  message_kind: telemetry.MessageKind,
) -> State(model, msg) {
  let msg_topic = codec.inbound_topic(msg)
  let msg_ref = codec.inbound_ref(msg)
  case codec.inbound_kind(msg) {
    codec.Join -> {
      let started_at = telemetry_start(state)
      case
        is_valid_topic(msg_topic, state.config) && !is_reserved_topic(msg_topic)
      {
        True ->
          handle_join(
            state,
            socket_id,
            msg_topic,
            codec.inbound_payload(msg),
            codec.inbound_join_ref(msg),
            msg_ref,
            started_at,
          )
        False -> reject_invalid_join(state, socket_id, msg, started_at)
      }
    }
    codec.Leave -> {
      let started_at = telemetry_start(state)
      use state <- with_message_rate_limit(
        state,
        socket_id,
        fn() { [#("kind", "leave")] },
        started_at,
        message_kind,
      )
      case is_valid_topic(msg_topic, state.config) {
        False -> {
          state.logger
          |> log.warn("Leave dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", topic.sanitize_for_log(msg_topic)),
          ])
          state
        }
        True ->
          handle_leave(
            state,
            socket_id,
            msg_topic,
            codec.inbound_join_ref(msg),
            msg_ref,
          )
      }
    }
    codec.Heartbeat -> {
      let started_at = telemetry_start(state)
      use state <- with_message_rate_limit(
        state,
        socket_id,
        fn() { [#("kind", "heartbeat")] },
        started_at,
        telemetry.HeartbeatMessage,
      )
      let state = handle_heartbeat(state, socket_id, msg_ref)
      emit_message_stop(
        state,
        started_at,
        telemetry.HeartbeatMessage,
        telemetry.MessageHandled,
        telemetry.NotApplicable,
      )
      state
    }
    codec.Event(event_name) -> {
      let started_at = telemetry_start(state)
      use state <- with_message_rate_limit(
        state,
        socket_id,
        fn() {
          [
            #("topic", topic.sanitize_for_log(msg_topic)),
            #("event", topic.sanitize_for_log(event_name)),
          ]
        },
        started_at,
        message_kind,
      )
      let resolved = resolve_event_topic(state, socket_id, msg_topic)
      case
        is_valid_topic(resolved, state.config),
        is_valid_event(event_name, state.config)
      {
        True, True ->
          handle_in_subscribed(
            state,
            socket_id,
            resolved,
            event_name,
            codec.inbound_payload(msg),
            codec.inbound_join_ref(msg),
            msg_ref,
            started_at,
            message_kind,
          )
        False, _ -> {
          state.logger
          |> log.warn("Event dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", topic.sanitize_for_log(msg_topic)),
            #("event", topic.sanitize_for_log(event_name)),
          ])
          state
        }
        True, False -> {
          state.logger
          |> log.warn("Event dropped: invalid event", [
            #("socket_id", socket_id),
            #("topic", msg_topic),
            #("event", topic.sanitize_for_log(event_name)),
          ])
          state
        }
      }
    }
  }
}

/// Resolve the topic for an inbound Event when the codec opted into
/// topicless events (see `codec.with_topicless_events`).
fn resolve_event_topic(
  state: State(model, msg),
  socket_id: String,
  requested: String,
) -> String {
  case requested {
    "" ->
      case dict.get(state.sockets, socket_id) {
        Ok(socket) ->
          case
            codec.topicless_events(socket.codec),
            set.to_list(socket.subscribed_topics)
          {
            True, [only] -> only
            _, _ -> requested
          }
        Error(Nil) -> requested
      }
    _ -> requested
  }
}

fn is_valid_topic(topic_name: String, config: Config) -> Bool {
  string.byte_size(topic_name) <= config.max_topic_length
  && result.is_ok(topic.validate(topic_name))
}

/// Topics under the `beryl:` prefix are reserved for internal machinery.
fn is_reserved_topic(topic_name: String) -> Bool {
  string.starts_with(topic_name, "beryl:")
}

/// Event names under the `phx_` prefix are reserved by the protocol.
fn is_valid_event(event_name: String, config: Config) -> Bool {
  string.byte_size(event_name) <= config.max_event_length
  && !string.starts_with(event_name, "phx_")
  && result.is_ok(topic.validate_event(event_name))
}

/// Apply the decoded-message limiter before semantic validation. Metadata is
/// built only on the over-rate path, and attacker-driven drops log at debug.
fn with_message_rate_limit(
  state: State(model, msg),
  socket_id: String,
  metadata: fn() -> List(#(String, String)),
  started_at: Int,
  kind: telemetry.MessageKind,
  next: fn(State(model, msg)) -> State(model, msg),
) -> State(model, msg) {
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed {
    False -> {
      state.logger
      |> log.debug("Message rate limited", [
        #("socket_id", socket_id),
        ..metadata()
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageRateLimited,
        telemetry.NotApplicable,
      )
      state
    }
    True -> next(state)
  }
}

fn reject_invalid_join(
  state: State(model, msg),
  socket_id: String,
  msg: codec.Inbound,
  started_at: Int,
) -> State(model, msg) {
  let safe_topic = topic.sanitize_for_log(codec.inbound_topic(msg))
  state.logger
  |> log.warn("Join rejected: invalid topic", [
    #("socket_id", socket_id),
    #("topic", safe_topic),
  ])
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
      state
    }
    Ok(socket) -> {
      let reply =
        codec.encode_reply(socket.codec)(
          codec.inbound_join_ref(msg),
          codec.inbound_ref(msg),
          codec.inbound_topic(msg),
          codec.StatusError,
          error_reason("invalid_topic"),
        )
      let _send_result = send_frame_logged(state, socket, safe_topic, reply)
      emit_join_stop(state, started_at, telemetry.JoinInvalidTopic)
      state
    }
  }
}

// ── Joins ───────────────────────────────────────────────────────────────────

fn handle_join(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> State(model, msg) {
  let #(state, join_allowed) = check_join_rate(state, socket_id)
  case join_allowed {
    False -> {
      state.logger
      |> log.warn("Join rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      send_error_reply(
        state,
        socket_id,
        topic_name,
        join_ref,
        ref,
        error_reason("rate_limited"),
      )
      emit_join_stop(state, started_at, telemetry.JoinRateLimited)
      state
    }
    True ->
      handle_join_inner(
        state,
        socket_id,
        topic_name,
        payload,
        join_ref,
        ref,
        started_at,
      )
  }
}

fn handle_join_inner(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      state.logger
      |> log.debug("Join ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "socket_not_found"),
      ])
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
      state
    }
    Ok(socket) ->
      case can_join_topic(socket, topic_name, state.config) {
        False -> {
          state.logger
          |> log.warn("Join rejected: topic cap exceeded", [
            #("socket_id", socket_id),
            #("topic", topic_name),
          ])
          send_error_reply(
            state,
            socket_id,
            topic_name,
            join_ref,
            ref,
            error_reason("too_many_topics"),
          )
          emit_join_stop(state, started_at, telemetry.JoinTopicLimit)
          state
        }
        True -> {
          // Phoenix duplicate-join semantics: a join for an already-joined
          // topic replaces the previous instance. Close it first (the app
          // receives `Closed(topic, Normal)`) so cleanup keyed off closing
          // is never silently skipped by a rejoin. The join is queued
          // behind that close as a step, so it still waits for the close's
          // presence cleanup even when that cleanup is asynchronous.
          let deliver =
            StepDeliverJoin(topic_name, payload, join_ref, ref, started_at)
          case dict.has_key(socket.join_refs, topic_name) {
            True ->
              run(state, socket_id, [
                StepCloseTopic(topic_name, sock.Normal, ContDrive),
                deliver,
              ])
            False -> run(state, socket_id, [deliver])
          }
        }
      }
  }
}

fn can_join_topic(
  socket: SocketState(model, msg),
  topic_name: String,
  config: Config,
) -> Bool {
  config.max_joined_topics_per_socket <= 0
  || set.contains(socket.subscribed_topics, topic_name)
  || set.size(socket.subscribed_topics) < config.max_joined_topics_per_socket
}

// ── Leaves ──────────────────────────────────────────────────────────────────

fn handle_leave(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  msg_join_ref: Option(String),
  ref: Option(String),
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> {
      use <- bool.lazy_guard(
        when: is_stale_join_ref(socket, topic_name, msg_join_ref),
        return: fn() {
          state.logger
          |> log.debug("Leave dropped: stale join_ref", [
            #("socket_id", socket_id),
            #("topic", topic_name),
          ])
          state
        },
      )

      // Acknowledge the leave before closing, so the client sees the reply
      // to its own ref first and the terminal frame second — matching
      // Phoenix.
      case ref {
        Some(r) -> {
          let reply =
            codec.encode_reply(socket.codec)(
              joined_ref(socket, topic_name),
              Some(r),
              topic_name,
              codec.StatusOk,
              json.object([]),
            )
          let _send_result = send_frame_logged(state, socket, topic_name, reply)
          Nil
        }
        None -> Nil
      }

      run(state, socket_id, [
        StepCloseTopic(topic_name, sock.Normal, ContDrive),
      ])
    }
  }
}

/// A message is stale when it carries a join_ref from a previous channel
/// instance on this topic (the client rejoined since sending it).
fn is_stale_join_ref(
  socket: SocketState(model, msg),
  topic_name: String,
  msg_join_ref: Option(String),
) -> Bool {
  case msg_join_ref, joined_ref(socket, topic_name) {
    Some(sent), Some(current) -> sent != current
    _, _ -> False
  }
}

fn joined_ref(
  socket: SocketState(model, msg),
  topic_name: String,
) -> Option(String) {
  dict.get(socket.join_refs, topic_name)
  |> result.unwrap(None)
}

// ── Client messages ─────────────────────────────────────────────────────────

fn handle_in_subscribed(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  msg_join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      state.logger
      |> log.debug("Inbound message ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event_name),
        #("reason", "socket_not_found"),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      state
    }
    Ok(socket) ->
      case set.contains(socket.subscribed_topics, topic_name) {
        False ->
          reject_unjoined_event(
            state,
            socket,
            socket_id,
            topic_name,
            event_name,
            ref,
            started_at,
            kind,
          )
        True ->
          case is_stale_join_ref(socket, topic_name, msg_join_ref) {
            True -> {
              state.logger
              |> log.debug("Inbound message dropped: stale join_ref", [
                #("socket_id", socket_id),
                #("topic", topic_name),
                #("event", event_name),
              ])
              emit_message_stop(
                state,
                started_at,
                kind,
                telemetry.MessageStale,
                telemetry.NotApplicable,
              )
              state
            }
            False ->
              handle_in_rate_limited(
                state,
                socket,
                socket_id,
                topic_name,
                event_name,
                payload,
                ref,
                started_at,
                kind,
              )
          }
      }
  }
}

/// Reject an event pushed to a topic the socket has not joined, replying
/// with Phoenix's `unmatched topic` error when a ref is present.
fn reject_unjoined_event(
  state: State(model, msg),
  socket: SocketState(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, msg) {
  state.logger
  |> log.debug("Inbound message rejected", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("event", event_name),
    #("reason", "topic_not_joined"),
  ])
  case ref {
    Some(r) -> {
      let reply =
        codec.encode_reply(socket.codec)(
          None,
          Some(r),
          topic_name,
          codec.StatusError,
          error_reason("unmatched topic"),
        )
      let _send_result = send_frame_logged(state, socket, topic_name, reply)
      Nil
    }
    None -> Nil
  }
  emit_message_stop(
    state,
    started_at,
    kind,
    telemetry.MessageUnjoined,
    telemetry.NotApplicable,
  )
  state
}

fn handle_in_rate_limited(
  state: State(model, msg),
  socket: SocketState(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, msg) {
  let #(state, allowed) = check_channel_rate(state, socket_id, topic_name)
  case allowed {
    False -> {
      state.logger
      |> log.warn("Channel rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageRateLimited,
        telemetry.NotApplicable,
      )
      state
    }
    True ->
      route_inbound_message(
        state,
        socket,
        socket_id,
        topic_name,
        event_name,
        payload,
        ref,
        started_at,
        kind,
      )
  }
}

fn route_inbound_message(
  state: State(model, msg),
  socket: SocketState(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, msg) {
  state.logger
  |> log.debug("Inbound message routed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("event", event_name),
    #("ref", optional_string(ref)),
  ])
  let message_ref =
    option.map(ref, fn(ref) {
      sock.make_message_ref(
        topic: topic_name,
        join_ref: joined_ref(socket, topic_name),
        msg_ref: Some(ref),
      )
    })
  case message_ref {
    Some(message_ref) ->
      route_message_with_ref(
        state,
        socket,
        socket_id,
        topic_name,
        event_name,
        payload,
        message_ref,
        started_at,
        kind,
      )
    None ->
      deliver_client_message(
        state,
        socket_id,
        topic_name,
        event_name,
        payload,
        None,
        started_at,
        kind,
      )
  }
}

fn route_message_with_ref(
  state: State(model, msg),
  socket: SocketState(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  message_ref: ReplyRef,
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, msg) {
  case set.contains(socket.pending_reply_refs, message_ref) {
    True -> {
      state.logger
      |> log.warn("Inbound message rejected: reply ref already outstanding", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event_name),
      ])
      send_error_reply(
        state,
        socket_id,
        topic_name,
        sock.reply_ref_join_ref(message_ref),
        sock.reply_ref_msg_ref(message_ref),
        error_reason("duplicate_ref"),
      )
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageInvalid,
        telemetry.NotApplicable,
      )
      state
    }
    False ->
      deliver_client_message(
        state,
        socket_id,
        topic_name,
        event_name,
        payload,
        Some(message_ref),
        started_at,
        kind,
      )
  }
}

fn deliver_client_message(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  message_ref: Option(ReplyRef),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, msg) {
  let state = case message_ref {
    Some(message_ref) -> register_reply_ref(state, socket_id, message_ref)
    None -> state
  }
  run(state, socket_id, [
    StepInput(
      sock.Message(
        topic: topic_name,
        event: event_name,
        payload: payload,
        ref: message_ref,
      ),
      MessageSource(topic_name, kind, started_at),
      ContDrive,
    ),
  ])
}

// ── Binary frames ───────────────────────────────────────────────────────────

fn handle_binary_in(
  state: State(model, msg),
  socket_id: String,
  data: BitArray,
) -> State(model, msg) {
  let active_codec = case dict.get(state.sockets, socket_id) {
    Ok(socket) -> socket.codec
    Error(Nil) -> state.config.codec
  }
  case codec.decode_binary(active_codec) {
    Some(decode_binary) ->
      case decode_binary(data) {
        Error(err) -> {
          state.logger
          |> log.warn("Failed to decode binary wire protocol message", [
            #("socket_id", socket_id),
            #("error", codec.format_decode_error(err)),
          ])
          state
        }
        Ok(msg) ->
          dispatch_inbound(state, socket_id, msg, telemetry.BinaryMessage)
      }
    None -> handle_undecoded_binary_in(state, socket_id, data)
  }
}

/// Rate-limit and fan an undecoded binary frame out to each joined topic.
/// The frame keeps binary telemetry classification; attacker-driven drops
/// log at debug to avoid warning-level amplification.
fn handle_undecoded_binary_in(
  state: State(model, msg),
  socket_id: String,
  data: BitArray,
) -> State(model, msg) {
  let started_at = telemetry_start(state)
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed, dict.get(state.sockets, socket_id) {
    False, _ -> {
      state.logger
      |> log.debug("Binary message rate limited", [#("socket_id", socket_id)])
      emit_message_stop(
        state,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageRateLimited,
        telemetry.NotApplicable,
      )
      state
    }
    True, Error(Nil) -> {
      state.logger
      |> log.debug("Binary message ignored", [
        #("socket_id", socket_id),
        #("reason", "socket_not_found"),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      state
    }
    True, Ok(socket) -> {
      // Fan the raw frame out to every joined topic, in sorted order for
      // determinism. Subscription is re-checked per topic as the fan-out
      // runs (see `StepBinaryTopics`): an earlier delivery may have closed
      // it or stopped the socket, and a presence effect in one topic's
      // handler suspends the remaining topics rather than racing ahead.
      let topics =
        set.to_list(socket.subscribed_topics)
        |> list.sort(string.compare)
      case topics {
        [] -> {
          emit_message_stop(
            state,
            started_at,
            telemetry.BinaryMessage,
            telemetry.MessageUnjoined,
            telemetry.NotApplicable,
          )
          state
        }
        _ -> run(state, socket_id, [StepBinaryTopics(topics, data, started_at)])
      }
    }
  }
}

// ── Server-side info ────────────────────────────────────────────────────────

fn handle_app_info(
  state: State(model, msg),
  socket_id: String,
  message: msg,
) -> State(model, msg) {
  let started_at = telemetry_start(state)
  case dict.has_key(state.sockets, socket_id) {
    False -> {
      state.logger
      |> log.debug("Info dropped", [
        #("socket_id", socket_id),
        #("reason", "socket_not_found"),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      state
    }
    True ->
      run(state, socket_id, [
        StepInput(sock.Info(message), InfoSource(started_at), ContDrive),
      ])
  }
}

// ── The step machine ────────────────────────────────────────────────────────
//
// A socket's pending work — the rest of an effect list, the topics a
// teardown still has to close, the terminal frame a close still owes — is
// reified as a stack of `Step`s instead of living on the actor's call
// stack. That is what lets one socket park on an asynchronous presence
// mutation without parking the runtime: its remaining stack moves into
// `State.suspended` and is resumed, in the exact same order, when the
// acknowledgement arrives.

/// Run a socket's stack until it is empty or a presence mutation parks it.
fn run(
  state: State(model, msg),
  socket_id: String,
  stack: List(Step(msg)),
) -> State(model, msg) {
  case stack {
    [] -> state
    [step, ..rest] ->
      case exec_step(state, socket_id, step) {
        Continue(state, steps) ->
          run(state, socket_id, list.append(steps, rest))
        Await(state, op_id, op, timer, steps) ->
          State(
            ..state,
            suspended: dict.insert(
              state.suspended,
              socket_id,
              Suspension(
                op_id: op_id,
                op: op,
                timer: timer,
                stack: list.append(steps, rest),
              ),
            ),
          )
      }
  }
}

fn exec_step(
  state: State(model, msg),
  socket_id: String,
  step: Step(msg),
) -> Exec(model, msg) {
  case step {
    StepEffects(effects, pending, kicks, cont) ->
      run_effects(state, socket_id, effects, pending, kicks, cont)
    StepInput(input, source, cont) ->
      exec_input(state, socket_id, input, source, cont)
    StepDeliverJoin(topic_name, payload, join_ref, ref, started_at) ->
      exec_deliver_join(
        state,
        socket_id,
        topic_name,
        payload,
        join_ref,
        ref,
        started_at,
      )
    StepBinaryTopics(topics, data, started_at) ->
      exec_binary_topics(state, socket_id, topics, data, started_at)
    StepCloseTopic(topic_name, reason, cont) ->
      exec_close_topic(state, socket_id, topic_name, reason, cont)
    StepCloseCleanup(topic_name, close_join_ref, reason, kicks, stop, cont) ->
      exec_close_cleanup(
        state,
        socket_id,
        topic_name,
        CloseOutcome(
          close_join_ref: close_join_ref,
          reason: reason,
          kicks: kicks,
          stop: stop,
          cont: cont,
        ),
      )
    StepCloseFinish(topic_name, close_join_ref, reason, kicks, stop, cont) -> {
      send_terminal_frame(state, socket_id, topic_name, close_join_ref, reason)
      Continue(state, cont_steps(cont, kicks, stop))
    }
    StepDrive(kicks, stop) -> exec_drive(state, socket_id, kicks, stop)
    StepTeardown(reason) -> exec_teardown(state, socket_id, reason)
    StepTeardownTopics(topics, reason) ->
      case topics {
        [] -> Continue(state, [])
        [topic_name, ..rest] ->
          Continue(state, [
            StepCloseTopic(topic_name, reason, ContTeardownTopics(rest, reason)),
          ])
      }
    StepTeardownFinish(reason, connected_at, joined_channels) ->
      exec_teardown_finish(
        state,
        socket_id,
        reason,
        connected_at,
        joined_channels,
      )
    StepFinishUpdate(source, effects) -> {
      finish_update_telemetry(state, socket_id, source, effects)
      Continue(state, [])
    }
  }
}

/// The tail of a topic close, bundled so `exec_close_cleanup` does not
/// need six positional parameters.
type CloseOutcome {
  CloseOutcome(
    close_join_ref: Option(String),
    reason: StopReason,
    kicks: List(String),
    stop: Option(StopReason),
    cont: Cont,
  )
}

/// The steps that hand an effect list's (or topic close's) kicks and stop
/// to whatever was waiting for them.
fn cont_steps(
  cont: Cont,
  kicks: List(String),
  stop: Option(StopReason),
) -> List(Step(msg)) {
  case cont {
    ContDrive -> [StepDrive(kicks, stop)]
    ContKicks(rest) -> [StepDrive(list.append(rest, kicks), stop)]
    ContCloseTopic(topic_name, close_join_ref, reason, outer) -> [
      StepCloseCleanup(topic_name, close_join_ref, reason, kicks, stop, outer),
    ]
    // A teardown is already closing this socket's topics in order; a
    // `Closed` handler cannot kick or stop its way out of it.
    ContTeardownTopics(topics, reason) -> [StepTeardownTopics(topics, reason)]
    ContFinishUpdate(source, effects, outer) -> [
      StepFinishUpdate(source, effects),
      ..cont_steps(outer, kicks, stop)
    ]
  }
}

fn effects_callback_result(effects: List(Effect)) -> telemetry.CallbackResult {
  case effects {
    [] -> telemetry.NoReply
    [effect, ..rest] ->
      case effect {
        sock.ReplyOk(_, _) -> telemetry.Reply
        sock.ReplyError(_, _) -> telemetry.ReplyError
        sock.Push(_, _, _)
        | sock.Broadcast(_, _, _)
        | sock.BroadcastFrom(_, _, _) -> telemetry.Push
        sock.AcceptJoin(..)
        | sock.RejectJoin(..)
        | sock.PresenceTrack(..)
        | sock.PresenceUntrack(..)
        | sock.PushPresence(..)
        | sock.BroadcastPresence(..)
        | sock.KickTopic(..) -> effects_callback_result(rest)
      }
  }
}

fn emit_missing_socket_telemetry(
  state: State(model, msg),
  source: Source,
) -> Nil {
  case source {
    JoinSource(_, _, _, _, started_at) ->
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
    MessageSource(_, kind, started_at) ->
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
    InfoSource(started_at) ->
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
    ClosedSource -> Nil
  }
}

fn emit_stopped_update_telemetry(
  state: State(model, msg),
  source: Source,
) -> Nil {
  case source {
    JoinSource(_, _, _, _, started_at) ->
      emit_join_stop(state, started_at, telemetry.JoinHandlerRejected)
    MessageSource(_, kind, started_at) ->
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageHandled,
        telemetry.Stop,
      )
    InfoSource(started_at) ->
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageHandled,
        telemetry.Stop,
      )
    ClosedSource -> Nil
  }
}

fn finish_update_telemetry(
  state: State(model, msg),
  socket_id: String,
  source: Source,
  effects: List(Effect),
) -> Nil {
  case source {
    JoinSource(topic_name, _, _, _, started_at) -> {
      let outcome = case socket_subscribed(state, socket_id, topic_name) {
        True -> telemetry.JoinAccepted
        False -> telemetry.JoinHandlerRejected
      }
      emit_join_stop(state, started_at, outcome)
    }
    MessageSource(_, kind, started_at) ->
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageHandled,
        effects_callback_result(effects),
      )
    InfoSource(started_at) ->
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageHandled,
        effects_callback_result(effects),
      )
    ClosedSource -> Nil
  }
}

/// Deliver one event to the app's `update`, store the new model, and start
/// its effect list. Kick and stop follow-ups reach `cont` only once every
/// effect has been applied — they are never applied mid-list.
fn exec_input(
  state: State(model, msg),
  socket_id: String,
  input: Input(msg),
  source: Source,
  cont: Cont,
) -> Exec(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      emit_missing_socket_telemetry(state, source)
      Continue(state, cont_steps(cont, [], None))
    }
    Ok(socket) -> {
      let update = state.update
      let model = socket.model
      // Crash boundary — see internal.rescue. The error path discards the
      // callback result and tears down the narrowest safe scope.
      exec_update_result(
        state,
        socket_id,
        source,
        cont,
        internal.rescue(fn() { update(model, input) }),
      )
    }
  }
}

fn exec_update_result(
  state: State(model, msg),
  socket_id: String,
  source: Source,
  cont: Cont,
  result: Result(Next(model), String),
) -> Exec(model, msg) {
  case result {
    Error(crash) -> exec_update_crash(state, socket_id, source, cont, crash)
    Ok(sock.Stop(reason)) -> {
      state.logger
      |> log.debug("Update stopped socket", [
        #("socket_id", socket_id),
        #("reason", stop_reason_string(reason)),
      ])
      // A join answered with Stop is still unanswered on the wire: fail it
      // closed before the teardown frames.
      reject_stopped_join(state, socket_id, source)
      emit_stopped_update_telemetry(state, source)
      Continue(state, cont_steps(cont, [], Some(reason)))
    }
    Ok(sock.Next(new_model, effects)) -> {
      let pending = case source {
        JoinSource(topic_name, join_ref, msg_ref, ref, _) ->
          Some(Pending(topic_name, join_ref, msg_ref, ref))
        MessageSource(..) | InfoSource(..) | ClosedSource -> None
      }
      Continue(store_model(state, socket_id, new_model), [
        StepEffects(
          effects,
          pending,
          [],
          ContFinishUpdate(source, effects, cont),
        ),
      ])
    }
  }
}

/// Crash policy: joins are rejected and the socket survives; topic-scoped
/// events close just that topic; `Info` (no topic to attribute) tears down
/// the socket; a crash while handling `Closed` is logged and teardown
/// continues with the last good model.
fn exec_update_crash(
  state: State(model, msg),
  socket_id: String,
  source: Source,
  cont: Cont,
  crash: String,
) -> Exec(model, msg) {
  case source {
    JoinSource(topic_name, join_ref, msg_ref, _, started_at) -> {
      state.logger
      |> log.error("Update crashed handling join", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("crash", crash),
      ])
      send_error_reply(
        state,
        socket_id,
        topic_name,
        join_ref,
        msg_ref,
        error_reason("join crashed"),
      )
      emit_join_stop(state, started_at, telemetry.JoinCallbackFailed)
      Continue(state, cont_steps(cont, [], None))
    }
    MessageSource(topic_name, kind, started_at) -> {
      state.logger
      |> log.error("Update crashed; closing topic", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("crash", crash),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageCallbackFailed,
        telemetry.CallbackFailed,
      )
      Continue(state, [StepCloseTopic(topic_name, sock.Errored(crash), cont)])
    }
    InfoSource(started_at) -> {
      state.logger
      |> log.error("Update crashed handling info; closing socket", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageCallbackFailed,
        telemetry.CallbackFailed,
      )
      Continue(state, [
        StepTeardown(sock.Errored(crash)),
        ..cont_steps(cont, [], None)
      ])
    }
    ClosedSource -> {
      state.logger
      |> log.error("Update crashed handling closed", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      Continue(state, cont_steps(cont, [], None))
    }
  }
}

/// Fail closed when an update returns `Stop` while handling a join.
fn reject_stopped_join(
  state: State(model, msg),
  socket_id: String,
  source: Source,
) -> Nil {
  case source {
    JoinSource(topic_name, join_ref, msg_ref, ref, _) ->
      reject_unanswered_join(
        state,
        socket_id,
        Pending(topic_name, join_ref, msg_ref, ref),
      )
    MessageSource(..) | InfoSource(..) | ClosedSource -> Nil
  }
}

/// Fail-closed reply for a join the update never answered.
fn reject_unanswered_join(
  state: State(model, msg),
  socket_id: String,
  pending: Pending,
) -> Nil {
  send_error_reply(
    state,
    socket_id,
    pending.topic,
    pending.join_ref,
    pending.msg_ref,
    error_reason("join not acknowledged"),
  )
}

/// Deliver a join once whatever had to happen first (the close of a
/// duplicate instance, including its presence cleanup) has finished.
fn exec_deliver_join(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> Exec(model, msg) {
  // The Closed delivered for a duplicate join may have stopped the socket.
  use <- bool.lazy_guard(
    when: !dict.has_key(state.sockets, socket_id),
    return: fn() {
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
      Continue(state, [])
    },
  )
  state.logger
  |> log.debug("Join delivered", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("ref", optional_string(ref)),
    #("join_ref", optional_string(join_ref)),
  ])
  let pending_ref =
    sock.make_join_ref(topic: topic_name, join_ref: join_ref, msg_ref: ref)
  Continue(state, [
    StepInput(
      sock.Join(topic: topic_name, payload: payload, ref: pending_ref),
      JoinSource(topic_name, join_ref, ref, pending_ref, started_at),
      ContDrive,
    ),
  ])
}

/// Hand an undecodable binary frame to the next joined topic. Subscription
/// is re-checked per topic because an earlier delivery may have closed it.
fn exec_binary_topics(
  state: State(model, msg),
  socket_id: String,
  topics: List(String),
  data: BitArray,
  started_at: Int,
) -> Exec(model, msg) {
  case topics {
    [] -> Continue(state, [])
    [topic_name, ..rest] ->
      case socket_subscribed(state, socket_id, topic_name) {
        False -> Continue(state, [StepBinaryTopics(rest, data, started_at)])
        True ->
          Continue(state, [
            StepInput(
              sock.Binary(topic: topic_name, data: data),
              MessageSource(topic_name, telemetry.BinaryMessage, started_at),
              ContDrive,
            ),
            StepBinaryTopics(rest, data, started_at),
          ])
      }
  }
}

/// Process an update's follow-ups: tear the socket down if it returned
/// `Stop`, otherwise close kicked topics one at a time (each `Closed`
/// delivery may add further kicks). Terminates because every kick closes a
/// joined topic and closed topics cannot be re-kicked.
fn exec_drive(
  state: State(model, msg),
  socket_id: String,
  kicks: List(String),
  stop: Option(StopReason),
) -> Exec(model, msg) {
  case stop, kicks {
    Some(reason), _ -> Continue(state, [StepTeardown(reason)])
    None, [] -> Continue(state, [])
    None, [topic_name, ..rest] ->
      case socket_subscribed(state, socket_id, topic_name) {
        // A topic that is no longer joined drops out of the queue.
        False -> Continue(state, [StepDrive(rest, None)])
        True ->
          Continue(state, [
            StepCloseTopic(topic_name, sock.Shutdown, ContKicks(rest)),
          ])
      }
  }
}

/// Close one topic subscription: remove the subscription state, then
/// deliver `Closed` to the app. Subscription state is removed *before* the
/// `Closed` delivery, so pushes to the closing topic drop while broadcasts
/// still reach the topic's remaining subscribers. The auto-untrack and the
/// terminal frame follow in `StepCloseCleanup`/`StepCloseFinish`.
fn exec_close_topic(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  reason: StopReason,
  cont: Cont,
) -> Exec(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Continue(state, cont_steps(cont, [], None))
    Ok(socket) ->
      case dict.has_key(socket.join_refs, topic_name) {
        False -> Continue(state, cont_steps(cont, [], None))
        True -> {
          state.logger
          |> log.debug("Topic closed", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("reason", stop_reason_string(reason)),
          ])
          let close_join_ref = joined_ref(socket, topic_name)
          let socket =
            SocketState(
              ..socket,
              subscribed_topics: set.delete(
                socket.subscribed_topics,
                topic_name,
              ),
              join_refs: dict.delete(socket.join_refs, topic_name),
              pending_reply_refs: set.filter(socket.pending_reply_refs, fn(ref) {
                sock.reply_ref_topic(ref) != topic_name
              }),
            )
          let state = store_socket(state, socket)
          let state = remove_channel_bucket(state, socket_id, topic_name)
          let state = remove_topic_subscriber(state, socket_id, topic_name)
          Continue(state, [
            StepInput(
              sock.Closed(topic: topic_name, reason: reason),
              ClosedSource,
              ContCloseTopic(topic_name, close_join_ref, reason, cont),
            ),
          ])
        }
      }
  }
}

/// Remove a socket from a topic's subscriber set, unsubscribing from
/// PubSub and dropping the topic entry when it was the last subscriber.
fn remove_topic_subscriber(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> State(model, msg) {
  let subscribers =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
    |> set.delete(socket_id)
  case state.router {
    Some(router) -> process.send(router, IndexLeave(socket_id, topic_name))
    None -> Nil
  }
  case set.is_empty(subscribers) {
    True -> {
      case state.subscriber {
        Some(subscriber) -> pubsub.leave(subscriber, topic_name)
        None -> Nil
      }
      State(..state, topics: dict.delete(state.topics, topic_name))
    }
    False ->
      State(..state, topics: dict.insert(state.topics, topic_name, subscribers))
  }
}

/// Add a socket to a topic's subscriber set, joining the pg group when the
/// topic becomes locally active.
///
/// Prototype (#334): in a socket actor the set only ever holds that one
/// socket, and the router is told so it can keep the global index and the
/// pg subscription. That notification is a cast, not a call — the router
/// calls into socket actors during admission and shutdown, so a call back
/// would deadlock. It is sent from `subscribe_socket`, before the join
/// reply frame leaves this turn, so a client that acts on its own reply
/// cannot beat its index entry to the router. A broadcast from a third
/// process that races the cast still misses the socket: that is decision
/// 2's cast option and its documented window.
fn add_topic_subscriber(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> State(model, msg) {
  let existing =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
  case state.router {
    Some(router) -> process.send(router, IndexJoin(socket_id, topic_name))
    None ->
      case state.subscriber, set.is_empty(existing) {
        Some(subscriber), True -> pubsub.join(subscriber, topic_name)
        _, _ -> Nil
      }
  }
  State(
    ..state,
    topics: dict.insert(
      state.topics,
      topic_name,
      set.insert(existing, socket_id),
    ),
  )
}

/// Notify the client that its topic ended. Phoenix clients rely on
/// `phx_close`/`phx_error` to leave the joined state (and, for errors,
/// schedule a rejoin). Codecs without close/error encoders skip this.
fn send_terminal_frame(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  close_join_ref: Option(String),
  reason: StopReason,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) -> {
      let encoder = case reason {
        sock.Errored(_) -> codec.encode_error(socket.codec)
        sock.Normal | sock.Shutdown | sock.HeartbeatTimeout ->
          codec.encode_close(socket.codec)
      }
      case encoder {
        Some(encode) -> {
          let _send_result =
            send_frame_logged(
              state,
              socket,
              topic_name,
              encode(close_join_ref, topic_name),
            )
          Nil
        }
        None -> Nil
      }
    }
  }
}

/// Tear down a whole socket: close every joined topic in sorted order
/// (delivering `Closed`), then close the transport connection and drop
/// socket state. Nested stop requests are ignored (the socket is already
/// tearing down), and a topic already closed by a nested kick is skipped
/// by `exec_close_topic`'s own joined check. No topic can be joined during
/// teardown, so the list taken up front covers every close.
fn exec_teardown(
  state: State(model, msg),
  socket_id: String,
  reason: StopReason,
) -> Exec(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Continue(state, [])
    Ok(socket) -> {
      state.logger
      |> log.debug(
        "Socket teardown",
        list.append(
          [#("socket_id", socket_id), #("reason", stop_reason_string(reason))],
          joined_topics_metadata(socket),
        ),
      )
      Continue(state, [
        StepTeardownTopics(
          dict.keys(socket.join_refs)
            |> list.sort(string.compare),
          reason,
        ),
        StepTeardownFinish(
          reason,
          socket.connected_at,
          set.size(socket.subscribed_topics),
        ),
      ])
    }
  }
}

fn exec_teardown_finish(
  state: State(model, msg),
  socket_id: String,
  reason: StopReason,
  connected_at: Int,
  joined_channels: Int,
) -> Exec(model, msg) {
  let state = remove_socket_rate_limits(state, socket_id)
  // Actively close the transport connection after the terminal frames
  // above have been queued, so evicted sockets do not linger as zombies.
  // A no-op when the transport already closed or never registered a
  // closer.
  case dict.get(state.sockets, socket_id) {
    Ok(socket) -> socket.close()
    Error(Nil) -> Nil
  }
  telemetry.emit(
    state.config.telemetry,
    telemetry.SocketDisconnected(
      duration: case state.config.telemetry {
        True -> telemetry.duration_since(connected_at)
        False -> 0
      },
      joined_channels: joined_channels,
      reason: disconnect_reason_telemetry(reason),
    ),
  )
  Continue(
    State(
      ..state,
      sockets: dict.delete(state.sockets, socket_id),
      queued: dict.delete(state.queued, socket_id),
    ),
    [],
  )
}

fn socket_subscribed(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> Bool {
  case dict.get(state.sockets, socket_id) {
    Ok(socket) -> set.contains(socket.subscribed_topics, topic_name)
    Error(Nil) -> False
  }
}

// ── Effect interpreter ──────────────────────────────────────────────────────

/// Apply an update's effects strictly in list order. Frames are written as
/// each effect is applied and all writes go through this single actor, so
/// list order is wire order. `Push` validity is evaluated against the
/// subscription state *as of that point in the list*, so a `Push` ordered
/// after its topic's `AcceptJoin` is valid.
///
/// `PresenceTrack`/`PresenceUntrack` are asynchronous: they park the socket
/// (`Await`) with the *rest of this list* — plus the pending join, the
/// kicks collected so far, and the continuation — as the work to resume.
/// Nothing after such an effect is applied before the mutation has been
/// applied and its `presence_diff` broadcast, so an effect list still
/// behaves exactly as if the mutation had been synchronous.
///
/// When the list runs out, an unanswered pending join is rejected (fail
/// closed) and the collected kicks are handed to `cont`.
fn run_effects(
  state: State(model, msg),
  socket_id: String,
  effects: List(Effect),
  pending: Option(Pending),
  kicks: List(String),
  cont: Cont,
) -> Exec(model, msg) {
  case effects {
    [] -> {
      case pending {
        Some(pending_join) -> {
          state.logger
          |> log.warn("Join not acknowledged by update; rejecting", [
            #("socket_id", socket_id),
            #("topic", pending_join.topic),
          ])
          reject_unanswered_join(state, socket_id, pending_join)
        }
        None -> Nil
      }
      Continue(state, cont_steps(cont, kicks, None))
    }
    [sock.PresenceTrack(topic_name, key, meta), ..rest] ->
      start_presence_track(state, socket_id, topic_name, key, meta, [
        StepEffects(rest, pending, kicks, cont),
      ])
    [sock.PresenceUntrack(topic_name, key), ..rest] ->
      start_presence_untrack(state, socket_id, topic_name, key, [
        StepEffects(rest, pending, kicks, cont),
      ])
    [effect, ..rest] -> {
      let #(state, pending, kicks) =
        apply_effect(state, socket_id, effect, pending, kicks)
      run_effects(state, socket_id, rest, pending, kicks, cont)
    }
  }
}

/// Apply one synchronous effect, returning the accumulator the fold used
/// to thread: the next state, the still-unanswered pending join, and the
/// kicked topics collected so far.
fn apply_effect(
  state: State(model, msg),
  socket_id: String,
  effect: Effect,
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, msg), Option(Pending), List(String)) {
  case effect {
    sock.AcceptJoin(ref, reply) ->
      apply_accept_join(state, socket_id, ref, reply, pending, kicks)
    sock.RejectJoin(ref, reason) ->
      apply_reject_join(state, socket_id, ref, reason, pending, kicks)
    sock.ReplyOk(ref, payload) -> {
      let state = apply_reply(state, socket_id, ref, codec.StatusOk, payload)
      #(state, pending, kicks)
    }
    sock.ReplyError(ref, payload) -> {
      let state = apply_reply(state, socket_id, ref, codec.StatusError, payload)
      #(state, pending, kicks)
    }
    sock.Push(topic_name, event_name, payload) -> {
      apply_push(state, socket_id, topic_name, event_name, payload)
      #(state, pending, kicks)
    }
    sock.Broadcast(topic_name, event_name, payload) -> {
      broadcast_with_pubsub(state, topic_name, event_name, payload, None)
      #(state, pending, kicks)
    }
    sock.BroadcastFrom(topic_name, event_name, payload) -> {
      broadcast_with_pubsub(
        state,
        topic_name,
        event_name,
        payload,
        Some(socket_id),
      )
      #(state, pending, kicks)
    }
    sock.PushPresence(topic_name, event_name, encode) -> {
      case presence_snapshot(state, socket_id, topic_name, encode) {
        Ok(payload) ->
          apply_push(state, socket_id, topic_name, event_name, payload)
        Error(Nil) -> Nil
      }
      #(state, pending, kicks)
    }
    sock.BroadcastPresence(topic_name, event_name, encode) -> {
      case presence_snapshot(state, socket_id, topic_name, encode) {
        Ok(payload) ->
          broadcast_with_pubsub(state, topic_name, event_name, payload, None)
        Error(Nil) -> Nil
      }
      #(state, pending, kicks)
    }
    sock.KickTopic(topic_name) ->
      apply_kick_topic(state, socket_id, topic_name, pending, kicks)
    // Handled by `run_effects`, which parks the socket on them.
    sock.PresenceTrack(_, _, _) | sock.PresenceUntrack(_, _) -> #(
      state,
      pending,
      kicks,
    )
  }
}

fn apply_kick_topic(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, msg), Option(Pending), List(String)) {
  use <- bool.lazy_guard(
    when: !socket_subscribed(state, socket_id, topic_name)
      || list.contains(kicks, topic_name),
    return: fn() {
      state.logger
      |> log.warn("KickTopic ignored: topic not joined", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      #(state, pending, kicks)
    },
  )
  #(state, pending, list.append(kicks, [topic_name]))
}

fn apply_accept_join(
  state: State(model, msg),
  socket_id: String,
  ref: JoinRef,
  reply: Option(Json),
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, msg), Option(Pending), List(String)) {
  case matching_pending_join(ref, pending) {
    Some(pending_join) -> {
      let state = subscribe_socket(state, socket_id, pending_join)
      case dict.get(state.sockets, socket_id) {
        Ok(socket) -> {
          let response = option.unwrap(reply, json.object([]))
          let frame =
            codec.encode_reply(socket.codec)(
              pending_join.join_ref,
              pending_join.msg_ref,
              pending_join.topic,
              codec.StatusOk,
              response,
            )
          let _send_result =
            send_frame_logged(state, socket, pending_join.topic, frame)
          Nil
        }
        Error(Nil) -> Nil
      }
      state.logger
      |> log.debug("Join accepted", [
        #("socket_id", socket_id),
        #("topic", pending_join.topic),
      ])
      #(state, None, kicks)
    }
    None -> {
      warn_unmatched_join_answer(state, socket_id, ref, "AcceptJoin")
      #(state, pending, kicks)
    }
  }
}

fn apply_reject_join(
  state: State(model, msg),
  socket_id: String,
  ref: JoinRef,
  reason: Json,
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, msg), Option(Pending), List(String)) {
  case matching_pending_join(ref, pending) {
    Some(p) -> {
      state.logger
      |> log.debug("Join rejected", [
        #("socket_id", socket_id),
        #("topic", p.topic),
      ])
      send_error_reply(state, socket_id, p.topic, p.join_ref, p.msg_ref, reason)
      #(state, None, kicks)
    }
    None -> {
      warn_unmatched_join_answer(state, socket_id, ref, "RejectJoin")
      #(state, pending, kicks)
    }
  }
}

fn matching_pending_join(
  ref: JoinRef,
  pending: Option(Pending),
) -> Option(Pending) {
  case pending {
    Some(p) ->
      case sock.join_refs_match(ref, p.ref) {
        True -> Some(p)
        False -> None
      }
    None -> None
  }
}

fn warn_unmatched_join_answer(
  state: State(model, msg),
  socket_id: String,
  ref: JoinRef,
  effect_name: String,
) -> Nil {
  state.logger
  |> log.warn(effect_name <> " ignored: no matching pending join", [
    #("socket_id", socket_id),
    #("topic", sock.join_ref_topic(ref)),
  ])
}

/// Commit an accepted join: record the subscription and join_ref, add the
/// socket to the topic's subscriber set, and subscribe the runtime to
/// PubSub when it is the topic's first local subscriber.
fn subscribe_socket(
  state: State(model, msg),
  socket_id: String,
  pending_join: Pending,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> {
      let socket =
        SocketState(
          ..socket,
          subscribed_topics: set.insert(
            socket.subscribed_topics,
            pending_join.topic,
          ),
          join_refs: dict.insert(
            socket.join_refs,
            pending_join.topic,
            pending_join.join_ref,
          ),
        )
      store_socket(state, socket)
      |> add_topic_subscriber(socket_id, pending_join.topic)
    }
  }
}

/// Send a reply for a stored `ReplyRef`.
///
/// Reply refs are single-use and only valid while their topic is open: a ref
/// that was already answered, or whose topic has since closed (including
/// across a leave/rejoin), is dropped rather than sent as a stale/duplicate
/// reply.
fn apply_reply(
  state: State(model, msg),
  socket_id: String,
  ref: ReplyRef,
  status: codec.ReplyStatus,
  payload: Json,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) ->
      case set.contains(socket.pending_reply_refs, ref) {
        False -> {
          state.logger
          |> log.warn("Reply ignored: unknown or already-answered ref", [
            #("socket_id", socket_id),
            #("topic", sock.reply_ref_topic(ref)),
          ])
          state
        }
        True -> {
          let frame =
            codec.encode_reply(socket.codec)(
              sock.reply_ref_join_ref(ref),
              sock.reply_ref_msg_ref(ref),
              sock.reply_ref_topic(ref),
              status,
              payload,
            )
          let _send_result =
            send_frame_logged(state, socket, sock.reply_ref_topic(ref), frame)
          store_socket(
            state,
            SocketState(
              ..socket,
              pending_reply_refs: set.delete(socket.pending_reply_refs, ref),
            ),
          )
        }
      }
  }
}

/// Record a message reply ref as outstanding for a socket.
fn register_reply_ref(
  state: State(model, msg),
  socket_id: String,
  ref: ReplyRef,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) ->
      store_socket(
        state,
        SocketState(
          ..socket,
          pending_reply_refs: set.insert(socket.pending_reply_refs, ref),
        ),
      )
  }
}

/// Push to this socket on a joined topic; pushes to unjoined topics are
/// dropped with a warning (order pushes after their topic's `AcceptJoin`).
fn apply_push(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Json,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) ->
      case set.contains(socket.subscribed_topics, topic_name) {
        False ->
          state.logger
          |> log.warn("Push dropped: topic not joined", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("event", event_name),
          ])
        True -> {
          let frame =
            codec.encode_push(socket.codec)(topic_name, event_name, payload)
          let _send_result = send_frame_logged(state, socket, topic_name, frame)
          Nil
        }
      }
  }
}

// ── Presence effects ────────────────────────────────────────────────────────
//
// Presence mutations never block this actor. Each one is sent to the
// presence actor with an operation id and this runtime's acknowledgement
// subject; the socket that issued it parks until the acknowledgement comes
// back (see `run`), and only then is its `presence_diff` broadcast and the
// rest of its effect list applied. Snapshot reads (`PushPresence`,
// `BroadcastPresence`) go straight to presence's ETS read model, which the
// presence actor publishes before acknowledging — so a snapshot ordered
// after a mutation still sees it.

/// Why a presence mutation resolved without a normal, in-time
/// acknowledgement.
///
/// This is distinct from `Ok`/`Error` on the mutation itself: it lets
/// `finish_presence_op` tell an intentional, expected non-wait (`Stopping`)
/// apart from an actual failure (`NotRunning`, `TimedOut`), so only the
/// latter two are logged as failures.
type PresenceGiveUp {
  /// No presence actor is running; the mutation can never be acknowledged.
  PresenceNotRunning
  /// The runtime is shutting down: there is no runtime left to wait for or
  /// receive an acknowledgement, so the mutation was dispatched (or, for a
  /// track, deliberately not attempted) fire-and-forget. Not a failure.
  PresenceStopping
  /// The presence actor did not acknowledge within `presence_op_timeout_ms`.
  PresenceTimedOut
}

/// Send a presence mutation and park the socket on its acknowledgement.
///
/// Three things can prevent the park: no presence actor is running (the
/// mutation can never be acknowledged), or the runtime is shutting down
/// (there will be no runtime left to receive the acknowledgement). Both
/// resolve the operation immediately as a failure rather than stranding
/// the socket, and neither invents a success.
fn begin_presence_op(
  state: State(model, msg),
  socket_id: String,
  handle: presence.Presence,
  op: PresenceOp,
  send: fn(Int, Subject(presence.MutationAck)) -> Nil,
  resume: List(Step(msg)),
) -> Exec(model, msg) {
  case presence.is_running(handle), state.stopping {
    False, _ -> {
      state.logger
      |> log.error("Presence mutation skipped: presence actor not running", [
        #("socket_id", socket_id),
        #("topic", presence_op_topic(op)),
      ])
      Continue(
        finish_presence_op(state, socket_id, op, Error(PresenceNotRunning)),
        resume,
      )
    }
    True, True -> {
      // Shutting down: fire and forget. A track cannot be completed at all
      // (its ref would be lost with the runtime), so it is dropped; the
      // untracks still need to reach presence.
      case op {
        TrackOp(_, _, _) ->
          state.logger
          |> log.warn("PresenceTrack dropped: runtime stopping", [
            #("socket_id", socket_id),
            #("topic", presence_op_topic(op)),
          ])
        UntrackOp(_, _, _) -> send(0, state.presence_ack)
      }
      Continue(
        finish_presence_op(state, socket_id, op, Error(PresenceStopping)),
        resume,
      )
    }
    True, False -> {
      let op_id = state.next_op_id
      send(op_id, state.presence_ack)
      let timer =
        process.send_after(
          state.self_subject,
          state.config.presence_op_timeout_ms,
          PresenceOpTimedOut(socket_id, op_id),
        )
      Await(State(..state, next_op_id: op_id + 1), op_id, op, timer, resume)
    }
  }
}

fn presence_op_topic(op: PresenceOp) -> String {
  case op {
    TrackOp(topic_name, _, _) -> topic_name
    UntrackOp(topic_name, _, _) -> topic_name
  }
}

/// Apply a presence mutation's result: update the runtime's own ref
/// bookkeeping and broadcast the `presence_diff` for it, at exactly the
/// position in the effect list where the mutation was issued.
///
/// `Error(reason)` means the mutation did not resolve with a normal, in-time
/// acknowledgement. A failed track records no ref and broadcasts no join —
/// it is not reported as a success. A failed untrack still broadcasts its
/// leave: the entry has already been dropped from this runtime's
/// bookkeeping, so leaving clients showing a presence nobody can ever
/// remove would be strictly worse. `PresenceStopping` is not a failure —
/// the mutation was intentionally dispatched (or, for a track, dropped)
/// fire-and-forget because the runtime is shutting down and has already
/// logged that decision — so it is the only reason that skips the
/// "failed"/"not acknowledged" error log.
fn finish_presence_op(
  state: State(model, msg),
  socket_id: String,
  op: PresenceOp,
  outcome: Result(presence.MutationOutcome, PresenceGiveUp),
) -> State(model, msg) {
  case op, outcome {
    TrackOp(topic_name, key, replaced), Ok(presence.Tracked(ref, meta)) -> {
      let state =
        store_presence_ref(state, socket_id, topic_name, key, ref, meta)
      broadcast_presence_diff(
        state,
        topic_name,
        [presence.PresenceEntry(session_id: socket_id, key: key, meta: meta)],
        replaced,
      )
      state
    }
    TrackOp(topic_name, _key, replaced), Error(PresenceStopping) -> {
      // Already logged (as a warning) where shutdown decided not to wait;
      // nothing more to log here.
      case replaced {
        [] -> Nil
        _ -> broadcast_presence_diff(state, topic_name, [], replaced)
      }
      state
    }
    TrackOp(topic_name, key, replaced), Error(PresenceTimedOut) -> {
      let state = failed_track(state, socket_id, topic_name, key, replaced)
      // The mutation did reach the presence actor and may still be
      // applied: remember that an acknowledgement — and with it a ref only
      // the compensation will ever learn — is still owed for this socket.
      note_unacked_track(state, socket_id)
    }
    // `PresenceNotRunning` never reached the actor, and an `Untracked`
    // acknowledgement for a track is a protocol impossibility (an
    // acknowledgement only ever reaches the operation it was minted for).
    // Neither can leave an entry behind, so neither is owed compensation.
    TrackOp(topic_name, key, replaced), Error(PresenceNotRunning)
    | TrackOp(topic_name, key, replaced), Ok(presence.Untracked)
    -> failed_track(state, socket_id, topic_name, key, replaced)
    UntrackOp(topic_name, leaves, _), Ok(_) -> {
      broadcast_presence_diff(state, topic_name, [], leaves)
      state
    }
    UntrackOp(topic_name, leaves, automatic), Error(PresenceStopping) -> {
      // The batch untrack was actually dispatched to the presence actor
      // above (fire-and-forget); this is not a failure, just shutdown
      // choosing not to wait for its acknowledgement.
      state.logger
      |> log.debug(
        case automatic {
          True -> "Presence cleanup dispatched: runtime stopping"
          False -> "PresenceUntrack dispatched: runtime stopping"
        },
        [#("socket_id", socket_id), #("topic", topic_name)],
      )
      broadcast_presence_diff(state, topic_name, [], leaves)
      state
    }
    UntrackOp(topic_name, leaves, automatic), Error(PresenceNotRunning)
    | UntrackOp(topic_name, leaves, automatic), Error(PresenceTimedOut)
    -> {
      state.logger
      |> log.error(
        case automatic {
          True -> "Presence cleanup failed: not acknowledged"
          False -> "PresenceUntrack failed: not acknowledged"
        },
        [#("socket_id", socket_id), #("topic", topic_name)],
      )
      broadcast_presence_diff(state, topic_name, [], leaves)
      state
    }
  }
}

/// A track that resolved without a usable acknowledgement: log it, and
/// publish the leave of any entry it had already handed to the presence
/// actor as its replacement, rather than leave clients showing a presence
/// this runtime can no longer untrack. Nothing is recorded as tracked.
fn failed_track(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  key: String,
  replaced: List(presence.PresenceEntry),
) -> State(model, msg) {
  state.logger
  |> log.error("PresenceTrack failed: not acknowledged", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("key", key),
  ])
  case replaced {
    [] -> Nil
    _ -> broadcast_presence_diff(state, topic_name, [], replaced)
  }
  state
}

/// Record that a track the runtime gave up on may still be applied by the
/// presence actor, so shutdown knows this socket can still be owed an
/// entry whose ref nobody here will ever hold.
fn note_unacked_track(
  state: State(model, msg),
  socket_id: String,
) -> State(model, msg) {
  let outstanding =
    dict.get(state.unacked_tracks, socket_id)
    |> result.unwrap(0)
  State(
    ..state,
    unacked_tracks: dict.insert(
      state.unacked_tracks,
      socket_id,
      outstanding + 1,
    ),
  )
}

/// One of a socket's outstanding acknowledgements has now arrived (and been
/// compensated), so it no longer needs sweeping at shutdown.
fn clear_unacked_track(
  state: State(model, msg),
  socket_id: String,
) -> State(model, msg) {
  case dict.get(state.unacked_tracks, socket_id) {
    Error(Nil) | Ok(1) ->
      State(
        ..state,
        unacked_tracks: dict.delete(state.unacked_tracks, socket_id),
      )
    Ok(outstanding) ->
      State(
        ..state,
        unacked_tracks: dict.insert(
          state.unacked_tracks,
          socket_id,
          outstanding - 1,
        ),
      )
  }
}

fn store_presence_ref(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  key: String,
  ref: String,
  meta: Json,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> {
      let topic_refs =
        dict.get(socket.presence_refs, topic_name)
        |> result.unwrap(dict.new())
      store_socket(
        state,
        SocketState(
          ..socket,
          presence_refs: dict.insert(
            socket.presence_refs,
            topic_name,
            dict.insert(topic_refs, key, #(ref, meta)),
          ),
        ),
      )
    }
  }
}

/// Route an acknowledgement back to the socket waiting for it, finish the
/// mutation, resume that socket's parked work, and then deliver whatever
/// arrived for it in the meantime.
///
/// An acknowledgement for an operation this runtime already gave up on
/// (timed out, or abandoned during shutdown) matches no suspension, or
/// matches one with a different operation id, and is dropped — it can
/// never disturb a newer operation, because operation ids only ever
/// increase. If that dropped acknowledgement is a `Tracked`, though, the
/// presence actor really did apply it: nothing else will ever learn that
/// ref, so it is compensated with a precise untrack rather than left to
/// leak (or to double up should the socket retry the same track).
fn handle_presence_ack(
  state: State(model, msg),
  ack: presence.MutationAck,
) -> State(model, msg) {
  case dict.get(state.suspended, ack.tag) {
    Error(Nil) -> {
      state.logger
      |> log.debug("Presence acknowledgement ignored: no socket waiting", [
        #("socket_id", ack.tag),
        #("op_id", int.to_string(ack.op_id)),
      ])
      compensate_stale_ack(state, ack)
    }
    Ok(suspension) ->
      case suspension.op_id == ack.op_id {
        False -> {
          state.logger
          |> log.debug("Presence acknowledgement ignored: stale operation", [
            #("socket_id", ack.tag),
            #("op_id", int.to_string(ack.op_id)),
            #("awaiting_op_id", int.to_string(suspension.op_id)),
          ])
          compensate_stale_ack(state, ack)
        }
        True -> {
          let _cancelled = process.cancel_timer(suspension.timer)
          resume_socket(state, ack.tag, suspension, Ok(ack.outcome))
        }
      }
  }
}

/// Compensate a stale/unmatched acknowledgement that turns out to have
/// applied a track. The socket it was for has already moved on (timed
/// out, superseded by a newer operation, or abandoned another way), so
/// nothing else will ever store this ref or ever ask presence to remove
/// it — left alone, the entry would sit there forever, or sit there
/// twice over if the socket retried the same track after the timeout.
///
/// Untracking exactly this ref (never the session's other presences) nets
/// the stale mutation out to a no-op without disturbing anything a live
/// operation is doing. An `Untracked` acknowledgement needs no
/// compensation — nothing was left behind — and this itself never
/// reaches a live suspension: the op id it is sent under is freshly drawn
/// from the same monotonic counter as every real operation and never
/// recorded against one, so it cannot collide with a suspension for any
/// socket, including this one. A duplicate or repeated stale
/// acknowledgement is therefore self-limiting: its own acknowledgement is
/// an `Untracked`, which compensates nothing further.
///
/// Presence resolves the ref to its exact local CRDT tag. Runtime retries
/// supersede only runtime-owned refs, while public synchronous refs remain
/// independently addressable, so compensation cannot delete a newer public
/// track even when session, topic, and key are identical.
fn compensate_stale_ack(
  state: State(model, msg),
  ack: presence.MutationAck,
) -> State(model, msg) {
  case ack.outcome {
    presence.Untracked -> state
    // The acknowledgement this socket was still owed has now arrived, so
    // shutdown no longer has to sweep its session — whether or not a
    // presence actor is still around to act on the ref it carries.
    presence.Tracked(ref, _meta) ->
      untrack_stale_ref(clear_unacked_track(state, ack.tag), ack.tag, ref)
  }
}

/// Ask presence to remove exactly the ref a stale acknowledgement carried.
fn untrack_stale_ref(
  state: State(model, msg),
  socket_id: String,
  ref: String,
) -> State(model, msg) {
  case state.config.presence {
    None -> state
    Some(handle) ->
      case presence.is_running(handle) {
        False -> state
        True -> {
          let op_id = state.next_op_id
          presence.untrack_async(
            presence: handle,
            refs: [ref],
            tag: socket_id,
            op_id: op_id,
            reply: state.presence_ack,
          )
          state.logger
          |> log.debug(
            "Presence acknowledgement compensated: untracking stale entry",
            [#("socket_id", socket_id), #("ref", ref)],
          )
          State(..state, next_op_id: op_id + 1)
        }
      }
  }
}

fn handle_presence_timeout(
  state: State(model, msg),
  socket_id: String,
  op_id: Int,
) -> State(model, msg) {
  case dict.get(state.suspended, socket_id) {
    Error(Nil) -> state
    Ok(suspension) ->
      case suspension.op_id == op_id {
        False -> state
        True -> {
          state.logger
          |> log.error("Presence mutation timed out", [
            #("socket_id", socket_id),
            #("topic", presence_op_topic(suspension.op)),
            #("op_id", int.to_string(op_id)),
            #("timeout_ms", int.to_string(state.config.presence_op_timeout_ms)),
          ])
          resume_socket(state, socket_id, suspension, Error(PresenceTimedOut))
        }
      }
  }
}

fn resume_socket(
  state: State(model, msg),
  socket_id: String,
  suspension: Suspension(msg),
  outcome: Result(presence.MutationOutcome, PresenceGiveUp),
) -> State(model, msg) {
  let state = State(..state, suspended: dict.delete(state.suspended, socket_id))
  let state = finish_presence_op(state, socket_id, suspension.op, outcome)
  // `run` may park the socket again on a later presence effect; the drain
  // then stops and leaves the rest of the queue for the next resume.
  drain_queue(run(state, socket_id, suspension.stack), socket_id)
}

/// Start a `PresenceTrack`. Tracking a key this socket already holds is an
/// atomic replacement: the previous ref goes to the presence actor with
/// the new entry, so the topic never materializes a snapshot without the
/// key, and the replacement is published as one leave plus one join.
fn start_presence_track(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  key: String,
  meta: Json,
  resume: List(Step(msg)),
) -> Exec(model, msg) {
  case state.config.presence, dict.get(state.sockets, socket_id) {
    None, _ -> {
      state.logger
      |> log.warn("PresenceTrack dropped: no presence handle configured", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      Continue(state, resume)
    }
    Some(_), Error(Nil) -> Continue(state, resume)
    Some(handle), Ok(socket) -> {
      let topic_refs =
        dict.get(socket.presence_refs, topic_name)
        |> result.unwrap(dict.new())
      let previous = dict.get(topic_refs, key)
      // `begin_presence_op` drops a track fire-and-forget under this exact
      // condition (running actor, stopping runtime): the mutation can never
      // reach the presence actor as a replace, so the previous ref must
      // stay exactly where it is — both in this socket's bookkeeping and,
      // untouched, in the presence actor's CRDT — rather than being
      // stripped here and forgotten. Left in place, it is picked up like
      // any other still-held ref by this topic's automatic close cleanup
      // (immediately following, in the same turn, when this `PresenceTrack`
      // came from `Closed`; otherwise whenever teardown later closes the
      // topic), which is what actually untracks it from presence and
      // broadcasts its leave, in that order.
      let dropping_for_stop = state.stopping && presence.is_running(handle)
      // The old entry is handed to the presence actor now; nothing else
      // for this socket runs before the acknowledgement, so dropping it
      // here cannot expose an intermediate view.
      let state = case previous, dropping_for_stop {
        _, True -> state
        Error(Nil), False -> state
        Ok(_), False ->
          store_socket(
            state,
            SocketState(
              ..socket,
              presence_refs: dict.insert(
                socket.presence_refs,
                topic_name,
                dict.delete(topic_refs, key),
              ),
            ),
          )
      }
      let op =
        TrackOp(
          topic: topic_name,
          key: key,
          replaced: case previous, dropping_for_stop {
            _, True -> []
            Ok(#(_ref, old_meta)), False -> [
              presence.PresenceEntry(
                session_id: socket_id,
                key: key,
                meta: old_meta,
              ),
            ]
            Error(Nil), False -> []
          },
        )
      begin_presence_op(
        state,
        socket_id,
        handle,
        op,
        fn(op_id, reply) {
          presence.track_async(
            presence: handle,
            topic: topic_name,
            key: key,
            session_id: socket_id,
            meta: meta,
            replace: option.from_result(
              result.map(previous, fn(entry) { entry.0 }),
            ),
            tag: socket_id,
            op_id: op_id,
            reply: reply,
          )
        },
        resume,
      )
    }
  }
}

/// Start a `PresenceUntrack`. A key the socket does not hold is ignored
/// with a debug log and never parks the socket.
fn start_presence_untrack(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  key: String,
  resume: List(Step(msg)),
) -> Exec(model, msg) {
  case state.config.presence, dict.get(state.sockets, socket_id) {
    None, Ok(_) -> {
      state.logger
      |> log.warn("PresenceUntrack dropped: no presence handle configured", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      Continue(state, resume)
    }
    _, Error(Nil) -> Continue(state, resume)
    Some(handle), Ok(socket) -> {
      let topic_refs =
        dict.get(socket.presence_refs, topic_name)
        |> result.unwrap(dict.new())
      case dict.get(topic_refs, key) {
        Error(Nil) -> {
          state.logger
          |> log.debug("PresenceUntrack ignored: key not tracked", [
            #("socket_id", socket_id),
            #("topic", topic_name),
          ])
          Continue(state, resume)
        }
        Ok(tracked) ->
          begin_key_untrack(
            store_socket(
              state,
              SocketState(
                ..socket,
                presence_refs: dict.insert(
                  socket.presence_refs,
                  topic_name,
                  dict.delete(topic_refs, key),
                ),
              ),
            ),
            socket_id,
            handle,
            topic_name,
            key,
            tracked,
            resume,
          )
      }
    }
  }
}

fn begin_key_untrack(
  state: State(model, msg),
  socket_id: String,
  handle: presence.Presence,
  topic_name: String,
  key: String,
  tracked: #(String, Json),
  resume: List(Step(msg)),
) -> Exec(model, msg) {
  let #(ref, meta) = tracked
  begin_presence_op(
    state,
    socket_id,
    handle,
    UntrackOp(
      topic: topic_name,
      leaves: [
        presence.PresenceEntry(session_id: socket_id, key: key, meta: meta),
      ],
      automatic: False,
    ),
    fn(op_id, reply) {
      presence.untrack_async(
        presence: handle,
        refs: [ref],
        tag: socket_id,
        op_id: op_id,
        reply: reply,
      )
    },
    resume,
  )
}

/// Untrack every presence the runtime still holds for a closing
/// socket/topic pair and broadcast the corresponding leaves — the
/// Phoenix-style safety net for apps that do not untrack explicitly from
/// their `Closed` handling. Keys already untracked by the app are gone
/// from the map and produce no duplicate diff.
///
/// The whole topic is one batch: one message to the presence actor, one
/// acknowledgement, and one aggregate `presence_diff`, however many keys
/// the socket held.
fn exec_close_cleanup(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  close: CloseOutcome,
) -> Exec(model, msg) {
  let resume = [
    StepCloseFinish(
      topic_name,
      close.close_join_ref,
      close.reason,
      close.kicks,
      close.stop,
      close.cont,
    ),
  ]
  case state.config.presence, dict.get(state.sockets, socket_id) {
    Some(handle), Ok(socket) ->
      case dict.get(socket.presence_refs, topic_name) {
        Error(Nil) -> Continue(state, resume)
        Ok(topic_refs) ->
          begin_topic_cleanup(
            drop_topic_presence_refs(state, socket, topic_name),
            socket_id,
            handle,
            topic_name,
            dict.to_list(topic_refs),
            resume,
          )
      }
    _, _ -> Continue(state, resume)
  }
}

fn drop_topic_presence_refs(
  state: State(model, msg),
  socket: SocketState(model, msg),
  topic_name: String,
) -> State(model, msg) {
  store_socket(
    state,
    SocketState(
      ..socket,
      presence_refs: dict.delete(socket.presence_refs, topic_name),
    ),
  )
}

fn begin_topic_cleanup(
  state: State(model, msg),
  socket_id: String,
  handle: presence.Presence,
  topic_name: String,
  entries: List(#(String, #(String, Json))),
  resume: List(Step(msg)),
) -> Exec(model, msg) {
  use <- bool.guard(when: entries == [], return: Continue(state, resume))
  let refs = list.map(entries, fn(entry) { entry.1.0 })
  let leaves =
    list.map(entries, fn(entry) {
      presence.PresenceEntry(
        session_id: socket_id,
        key: entry.0,
        meta: entry.1.1,
      )
    })
  begin_presence_op(
    state,
    socket_id,
    handle,
    UntrackOp(topic: topic_name, leaves: leaves, automatic: True),
    fn(op_id, reply) {
      presence.untrack_async(
        presence: handle,
        refs: refs,
        tag: socket_id,
        op_id: op_id,
        reply: reply,
      )
    },
    resume,
  )
}

/// Read the topic's presence entries and run the app's encoder, both at
/// effect-application time so earlier presence effects in the same list
/// are already reflected: the presence actor publishes a topic's read-model
/// snapshot before acknowledging the mutation that changed it, and the
/// socket does not resume until that acknowledgement arrives. The encoder
/// is app code and runs inside the crash boundary (see `internal.rescue`):
/// a crash drops the snapshot with an error log instead of taking down the
/// runtime.
fn presence_snapshot(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  encode: fn(List(presence.PresenceEntry)) -> Json,
) -> Result(Json, Nil) {
  case state.config.presence {
    None -> {
      state.logger
      |> log.warn("Presence snapshot dropped: no presence handle configured", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      Error(Nil)
    }
    Some(handle) ->
      case presence.list(handle, topic_name) {
        Error(Nil) -> {
          state.logger
          |> log.error("Presence snapshot failed", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("crash", "presence read model unavailable"),
          ])
          Error(Nil)
        }
        Ok(entries) ->
          case internal.rescue(fn() { encode(entries) }) {
            Ok(payload) -> Ok(payload)
            Error(crash) -> {
              state.logger
              |> log.error("Presence snapshot failed", [
                #("socket_id", socket_id),
                #("topic", topic_name),
                #("crash", crash),
              ])
              Error(Nil)
            }
          }
      }
  }
}

fn broadcast_presence_diff(
  state: State(model, msg),
  topic_name: String,
  joins: List(presence.PresenceEntry),
  leaves: List(presence.PresenceEntry),
) -> Nil {
  let diff =
    presence.diff(joins: [#(topic_name, joins)], leaves: [#(topic_name, leaves)])
  broadcast_with_pubsub(
    state,
    topic_name,
    "presence_diff",
    presence_wire.encode_diff(diff, topic_name),
    None,
  )
}

// ── Broadcasts ──────────────────────────────────────────────────────────────

/// Fan a message out to the topic's local subscribers, encoding per
/// recipient so connections with different codecs each get their own
/// framing.
fn local_broadcast(
  state: State(model, msg),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
) -> #(Int, Int) {
  let subscribers =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
    |> set.to_list()
  let recipients = case except {
    None -> subscribers
    Some(except_id) -> list.filter(subscribers, fn(id) { id != except_id })
  }
  state.logger
  |> log.debug("Broadcast dispatched", [
    #("topic", topic_name),
    #("event", event_name),
    #("recipient_count", int.to_string(list.length(recipients))),
    #("except", optional_string(except)),
  ])
  case state.router {
    // Socket actor: it is the only possible recipient, so encode and send
    // inline exactly as the shared runtime did.
    Some(_) ->
      list.fold(recipients, #(0, 0), fn(counts, socket_id) {
        case dict.get(state.sockets, socket_id) {
          Ok(socket) -> {
            let frame =
              codec.encode_push(socket.codec)(topic_name, event_name, payload)
            let send_result =
              send_frame_logged(state, socket, topic_name, frame)
            #(
              counts.0 + 1,
              counts.1
                + case send_result {
                Ok(Nil) -> 0
                Error(Nil) -> 1
              },
            )
          }
          Error(Nil) -> counts
        }
      })
    // Decision 1: the router resolves recipients and hands each one to its
    // own actor, so encoding happens on N schedulers instead of in this
    // turn, and only one process ever writes to a given transport.
    //
    // ponytail: send failures are no longer visible here, so the broadcast
    // telemetry reports zero of them. Ceiling: `send_failures` is dead in
    // this topology. Upgrade: have socket actors report failures back, or
    // move the counter into per-socket telemetry.
    None -> {
      list.each(recipients, fn(socket_id) {
        case dict.get(state.socket_actors, socket_id) {
          Ok(socket_actor) ->
            process.send(
              socket_actor,
              Broadcast(topic_name, event_name, payload, except),
            )
          Error(Nil) -> Nil
        }
      })
      #(list.length(recipients), 0)
    }
  }
}

fn emit_broadcast(
  state: State(model, msg),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
  origin: telemetry.BroadcastOrigin,
) -> Nil {
  let started_at = telemetry_start(state)
  let #(recipients, send_failures) =
    local_broadcast(state, topic_name, event_name, payload, except)
  use <- bool.guard(when: !state.config.telemetry, return: Nil)
  telemetry.emit(
    True,
    telemetry.BroadcastStop(
      duration: telemetry.duration_since(started_at),
      recipients: recipients,
      send_failures: send_failures,
      origin: origin,
    ),
  )
}

/// Local fan-out plus distributed forwarding when PubSub is configured.
/// Used by the effect interpreter, which runs inside the runtime actor —
/// the actor's own pid is the PubSub sender, so the runtime does not echo
/// the message back to itself.
fn broadcast_with_pubsub(
  state: State(model, msg),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
) -> Nil {
  // Prototype (#334): a socket actor owns neither the topic index nor the
  // PubSub handle, so everything it originates goes to the router, which
  // fans out locally (decision 1's hop) and forwards to other nodes.
  //
  // This socket's own copy is sent inline first, so a broadcast to a topic
  // it is joined to still lands in effect-list order instead of arriving a
  // round trip later, behind the frames that followed it. The only
  // `except` a socket actor ever originates is its own id (`BroadcastFrom`),
  // so the exclusion handed to the router is always this socket.
  use <- with_router(state, fn(router) {
    case except, dict.keys(state.sockets) {
      None, [socket_id] -> {
        let _counts =
          local_broadcast(state, topic_name, event_name, payload, None)
        process.send(
          router,
          Broadcast(topic_name, event_name, payload, Some(socket_id)),
        )
      }
      _, _ ->
        process.send(router, Broadcast(topic_name, event_name, payload, except))
    }
  })
  emit_broadcast(
    state,
    topic_name,
    event_name,
    payload,
    except,
    telemetry.Local,
  )
  case state.pubsub {
    Some(ps) ->
      case except {
        None ->
          pubsub.broadcast_from(
            ps,
            process.self(),
            topic_name,
            event_name,
            payload,
          )
        Some(socket_id) ->
          pubsub.broadcast_from_socket(
            ps,
            process.self(),
            socket_id,
            topic_name,
            event_name,
            payload,
          )
      }
    None -> Nil
  }
}

/// Prototype (#334): branch on topology. In a socket actor, run
/// `in_socket_actor` with the router's subject and stop; in the router,
/// fall through to the calling function's body.
fn with_router(
  state: State(model, msg),
  in_socket_actor: fn(Subject(Msg(msg))) -> Nil,
  in_router: fn() -> Nil,
) -> Nil {
  case state.router {
    Some(router) -> in_socket_actor(router)
    None -> in_router()
  }
}

fn handle_remote_broadcast(
  state: State(model, msg),
  pubsub_msg: pubsub.Message(Json),
) -> State(model, msg) {
  let except = case pubsub_msg.from {
    pubsub.FromSocket(_, socket_id) -> Some(socket_id)
    pubsub.System | pubsub.FromPid(_) -> None
  }
  emit_broadcast(
    state,
    pubsub_msg.topic,
    pubsub_msg.event,
    pubsub_msg.payload,
    except,
    telemetry.Remote,
  )
  state
}

// ── Rate limiting ───────────────────────────────────────────────────────────

fn check_message_rate(
  state: State(model, msg),
  socket_id: String,
) -> #(State(model, msg), Bool) {
  case state.config.message_limits {
    None -> #(state, True)
    Some(limits) -> {
      let bucket =
        dict.get(state.message_buckets, socket_id)
        |> result.lazy_unwrap(fn() { rate_limit.new_bucket(limits) })
      let #(bucket, taken) = rate_limit.take(bucket)
      #(
        State(
          ..state,
          message_buckets: dict.insert(state.message_buckets, socket_id, bucket),
        ),
        result.is_ok(taken),
      )
    }
  }
}

fn check_join_rate(
  state: State(model, msg),
  socket_id: String,
) -> #(State(model, msg), Bool) {
  case state.config.join_limits {
    None -> #(state, True)
    Some(limits) -> {
      let bucket =
        dict.get(state.join_buckets, socket_id)
        |> result.lazy_unwrap(fn() { rate_limit.new_bucket(limits) })
      let #(bucket, taken) = rate_limit.take(bucket)
      #(
        State(
          ..state,
          join_buckets: dict.insert(state.join_buckets, socket_id, bucket),
        ),
        result.is_ok(taken),
      )
    }
  }
}

/// Per-topic message rate limits: the first matching topic pattern wins,
/// falling back to the global channel limits.
fn resolve_channel_limits(
  config: Config,
  topic_name: String,
) -> Option(RateLimitConfig) {
  case
    list.find(config.topic_rates, fn(entry) {
      topic.matches(entry.0, topic_name)
    })
  {
    Ok(#(_pattern, limits)) -> limits
    Error(Nil) -> config.channel_limits
  }
}

fn check_channel_rate(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> #(State(model, msg), Bool) {
  case resolve_channel_limits(state.config, topic_name) {
    None -> #(state, True)
    Some(limits) -> take_channel_token(state, socket_id, topic_name, limits)
  }
}

fn take_channel_token(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  limits: RateLimitConfig,
) -> #(State(model, msg), Bool) {
  let socket_buckets =
    dict.get(state.channel_buckets, socket_id)
    |> result.unwrap(dict.new())
  let cap = state.config.channel_limiter_max_keys_per_socket
  let over_cap = case dict.has_key(socket_buckets, topic_name) {
    True -> False
    False -> cap > 0 && dict.size(socket_buckets) >= cap
  }
  use <- bool.guard(when: over_cap, return: #(state, False))
  let bucket =
    dict.get(socket_buckets, topic_name)
    |> result.lazy_unwrap(fn() { rate_limit.new_bucket(limits) })
  let #(bucket, taken) = rate_limit.take(bucket)
  let socket_buckets = dict.insert(socket_buckets, topic_name, bucket)
  #(
    State(
      ..state,
      channel_buckets: dict.insert(
        state.channel_buckets,
        socket_id,
        socket_buckets,
      ),
    ),
    result.is_ok(taken),
  )
}

fn remove_channel_bucket(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
) -> State(model, msg) {
  case dict.get(state.channel_buckets, socket_id) {
    Error(Nil) -> state
    Ok(socket_buckets) ->
      State(
        ..state,
        channel_buckets: dict.insert(
          state.channel_buckets,
          socket_id,
          dict.delete(socket_buckets, topic_name),
        ),
      )
  }
}

fn remove_socket_rate_limits(
  state: State(model, msg),
  socket_id: String,
) -> State(model, msg) {
  State(
    ..state,
    message_buckets: dict.delete(state.message_buckets, socket_id),
    join_buckets: dict.delete(state.join_buckets, socket_id),
    channel_buckets: dict.delete(state.channel_buckets, socket_id),
  )
}

// ── Small helpers ───────────────────────────────────────────────────────────

fn error_reason(text: String) -> Json {
  json.object([#("reason", json.string(text))])
}

fn store_socket(
  state: State(model, msg),
  socket: SocketState(model, msg),
) -> State(model, msg) {
  State(..state, sockets: dict.insert(state.sockets, socket.id, socket))
}

fn store_model(
  state: State(model, msg),
  socket_id: String,
  model: model,
) -> State(model, msg) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> store_socket(state, SocketState(..socket, model: model))
  }
}

/// Send a `phx_reply` error to a socket (join rejections, rate limits).
fn send_error_reply(
  state: State(model, msg),
  socket_id: String,
  topic_name: String,
  join_ref: Option(String),
  msg_ref: Option(String),
  reason: Json,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) -> {
      let frame =
        codec.encode_reply(socket.codec)(
          join_ref,
          msg_ref,
          topic_name,
          codec.StatusError,
          reason,
        )
      let _send_result = send_frame_logged(state, socket, topic_name, frame)
      Nil
    }
  }
}

fn send_frame(
  socket: SocketState(model, msg),
  frame: codec.Frame,
) -> Result(Nil, Nil) {
  case frame {
    codec.TextFrame(text) -> socket.send(text)
    codec.BinaryFrame(data) -> socket.send_binary(data)
  }
}

fn frame_kind(frame: codec.Frame) -> String {
  case frame {
    codec.TextFrame(_) -> "text"
    codec.BinaryFrame(_) -> "binary"
  }
}

fn send_frame_logged(
  state: State(model, msg),
  socket: SocketState(model, msg),
  topic_name: String,
  frame: codec.Frame,
) -> Result(Nil, Nil) {
  let send_result = send_frame(socket, frame)
  case send_result {
    Ok(Nil) ->
      state.logger
      |> log.debug("Outbound frame sent", [
        #("socket_id", socket.id),
        #("topic", topic_name),
        #("frame_kind", frame_kind(frame)),
      ])
    Error(Nil) ->
      state.logger
      |> log.warn("Outbound frame failed", [
        #("socket_id", socket.id),
        #("topic", topic_name),
        #("frame_kind", frame_kind(frame)),
      ])
  }
  send_result
}

fn stop_reason_string(reason: StopReason) -> String {
  case reason {
    sock.Normal -> "normal"
    sock.Shutdown -> "shutdown"
    sock.HeartbeatTimeout -> "heartbeat_timeout"
    sock.Errored(message) -> message
  }
}

fn optional_string(value: Option(String)) -> String {
  value
  |> option.unwrap("")
  |> topic.sanitize_for_log
}

fn joined_topics_metadata(
  socket: SocketState(model, msg),
) -> List(#(String, String)) {
  let topics = set.to_list(socket.subscribed_topics)
  [
    #("joined_topic_count", int.to_string(list.length(topics))),
    #("joined_topics", string.join(topics, ",")),
  ]
}
