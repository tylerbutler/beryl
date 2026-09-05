//// Runtime actors for supervised app-side dispatch systems.
////
//// One router actor indexes every socket started through `beryl.child_spec`,
//// and one socket actor owns each connected socket. Both roles are generic
//// over the app's `model` and `message` types: each model lives in its socket
//// actor, typed `Info` messages arrive through that actor's mailbox, and no
//// value is ever type-erased. Transports reach the actors through monomorphic
//// closures captured by `beryl.child_spec`, so the frame-level transport SPI
//// stays unparameterized.
////
//// Transports decode inbound frames before the router forwards them. Socket
//// actors own protocol validation, rate limiting, heartbeat eviction, topic
//// membership, and effect interpretation. The router owns the global topic
//// index and broadcast fan-out. Each `update` returns a list of `Effect`s that
//// its socket actor applies strictly in order, so effect list order is wire
//// order.

import beryl/app_supervisor
import beryl/error as beryl_error
import beryl/internal
import beryl/log.{type Logger}
import beryl/presence
import beryl/presence/wire as presence_wire
import beryl/pubsub.{type PubSub}
import beryl/rate_limit.{type RateLimitConfig}
import beryl/socket.{
  type ConnectInfo, type ConnectSeed, type Effect, type Input, type JoinRef,
  type Mail, type Next, type ReplyRef, type StopReason, type Worker,
  type WorkerContext, type WorkerOutcome,
}
import beryl/telemetry
import beryl/topic.{type TopicPattern}
import beryl/wire/codec.{type Codec}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
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
pub type Message(message) {
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
    actor: Subject(Message(message)),
    actor_pid: process.Pid,
  )
  SocketDisconnected(socket_id: String)
  RouteText(socket_id: String, raw_text: String)
  RouteDecoded(socket_id: String, message: codec.Inbound)
  RouteDecodedBinary(socket_id: String, message: codec.Inbound)
  HandleBinary(socket_id: String, data: BitArray)
  /// A typed server-side message for one socket, sent through its
  /// `Sender`. Delivered to `update` as `Info(message)`.
  AppInfo(socket_id: String, message: message)
  /// Broadcast fan-out: local subscribers plus PubSub forwarding to other
  /// runtimes when PubSub is configured.
  Broadcast(topic: String, event: String, payload: Json, except: Option(String))
  RemoteBroadcast(pubsub.Message(Json))
  CheckHeartbeats
  GetStats(reply: Subject(StatsSnapshot))
  /// A presence mutation this runtime started has been applied (CRDT and
  /// read model both updated). Routed back to the socket waiting on it.
  PresenceAcknowledged(acknowledgement: presence.MutationAck)
  /// A presence mutation was not acknowledged in time. Ignored unless the
  /// socket is still waiting on exactly that operation.
  PresenceOperationTimedOut(socket_id: String, operation_id: Int)
  Stop(reply: Subject(app_supervisor.StopCompletion))
  /// A socket actor joined a topic. The router owns the global index and
  /// the pg subscription.
  IndexJoin(socket_id: String, topic: String)
  /// A socket actor left a topic.
  IndexLeave(socket_id: String, topic: String)
  /// A socket actor finished its teardown and is about to stop; the
  /// router drops it from the index and the actor table.
  SocketClosed(socket_id: String)
  /// The router died. Every socket actor monitors the router and stops on
  /// its `Down`, so router death takes the whole socket population with it
  /// (and the transports, which monitor the same pid, close the
  /// connections).
  RouterDown
  /// A socket actor exited without reporting `SocketClosed` first — it
  /// crashed, or was killed. The router sweeps its index and actor-table
  /// entries so a crashed actor cannot leak a phantom subscription.
  SocketActorDown(down: process.Down)
  /// Shut one socket actor down. Unlike `Stop` there is no reply — the
  /// router waits for `SocketClosed`, so a socket actor's teardown
  /// broadcasts still reach the router on their way out.
  StopSocketActor
  /// A socket actor never reported back during shutdown (its teardown is
  /// stuck in an app callback). The router kills the stragglers and stops.
  StopTimedOut
  /// Shutdown phase one. Finalize in-flight presence work while every
  /// other socket actor is still alive to receive the leaves it publishes;
  /// the shared runtime got this for free by doing it before its teardown
  /// loop.
  FinalizeForStop
  /// A socket actor finished shutdown phase one.
  StopPhaseDone
  /// A topic worker reported a callback result or its termination.
  ///
  /// `worker` identifies the reporting process. The socket drops a report
  /// from a worker that it no longer owns.
  WorkerReport(
    socket_id: String,
    topic: String,
    worker: Pid,
    report: WorkerReport,
  )
  /// A topic worker stopped. The socket actor monitors each worker that it
  /// starts. If an active worker stops, the actor closes its topic with an
  /// error. If a closing worker stops, the actor completes that close.
  WorkerDown(down: process.Down)
  /// A closing topic's worker did not report its termination in time.
  WorkerTerminateTimedOut(socket_id: String, worker: Pid)
  /// A socket actor was still `Booting` when its boot deadline expired: the
  /// admission that started it was cancelled, or the transport process died
  /// before it reached the router. The actor stops so the socket factory
  /// cannot accumulate never-admitted children. Ignored once the actor is
  /// `Active` or `Closing`.
  BootTimedOut
}

/// What a topic worker sends its socket actor.
pub type WorkerReport {
  /// A callback completed. If `closing` is `True`, the socket applies
  /// `effects` and then closes the topic.
  WorkerRan(effects: List(Effect), closing: Bool, source: Source)
  /// A callback panicked. The worker keeps its previous state and accepts no
  /// more work. The socket closes the topic and runs `on_terminate`.
  WorkerCrashed(crash: String, source: Source)
  /// `on_terminate` completed, or it panicked and set `crash`. The worker is
  /// stopping.
  WorkerTerminated(effects: List(Effect), crash: Option(String))
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

type State(model, message) {
  State(
    sockets: Dict(String, SocketState(model, message)),
    /// Topic -> set of subscribed socket ids.
    topics: Dict(String, Set(String)),
    config: Config,
    pubsub: Option(PubSub(Json)),
    /// Typed PubSub subscription owned by this runtime actor, present
    /// whenever `pubsub` is. Joins/leaves topics and folds broadcast
    /// delivery into the actor's selector.
    subscriber: Option(pubsub.Subscriber(Json)),
    logger: Logger,
    self_subject: Subject(Message(message)),
    init: fn(ConnectInfo(message)) -> #(model, List(Effect)),
    update: fn(model, Input(message)) -> Next(model),
    message_buckets: Dict(String, rate_limit.Bucket),
    join_buckets: Dict(String, rate_limit.Bucket),
    channel_buckets: Dict(String, Dict(String, rate_limit.Bucket)),
    /// Reply target for asynchronous presence mutations, folded into the
    /// actor's selector as `PresenceAcknowledged`.
    presence_acknowledgement: Subject(presence.MutationAck),
    /// Source of presence operation ids. Monotonic, so an acknowledgement
    /// for an abandoned operation can never be mistaken for a newer one.
    next_operation_id: Int,
    /// Sockets whose effect list is parked on a presence mutation, with
    /// the work to resume once it is acknowledged. Only these sockets are
    /// suspended: every other socket, broadcast, and system message keeps
    /// being processed.
    suspended: Dict(String, Suspension(message)),
    /// Socket-scoped messages that arrived while their socket was
    /// suspended, newest first. Delivered in arrival order once the socket
    /// resumes.
    queued: Dict(String, List(Message(message))),
    /// How many tracks per socket the runtime gave up on (timed out) while
    /// their acknowledgement could still arrive — the entries whose refs
    /// this runtime does not know and only learns from the late
    /// acknowledgement it compensates. Decremented as each one is
    /// compensated, and swept wholesale at shutdown, when no
    /// acknowledgement can be received any more.
    unacknowledged_tracks: Dict(String, Int),
    /// Set while the runtime is draining for shutdown. Presence mutations
    /// are then fire-and-forget: there is no longer a runtime to deliver
    /// the acknowledgement to.
    stopping: Bool,
    /// The process's topology-specific state. A socket actor is this same
    /// `State` with exactly one entry in `sockets`; router-only shutdown and
    /// actor-index fields cannot be constructed for that role.
    role: RuntimeRole(message),
  )
}

/// The router's record of one admitted socket actor. The monitor is the
/// crash side of the actor's lifecycle: a normal close reports
/// `SocketClosed` and is demonitored, while a crash is swept via
/// `SocketActorDown`.
type SocketActorRef(message) {
  SocketActorRef(
    subject: Subject(Message(message)),
    pid: process.Pid,
    monitor: process.Monitor,
    close: fn() -> Nil,
  )
}

type RuntimeRole(message) {
  RouterRole(
    socket_actors: Dict(String, SocketActorRef(message)),
    stop_reply: Option(Subject(app_supervisor.StopCompletion)),
    stop_finalized: Int,
  )
  SocketActorRole(
    router: Subject(Message(message)),
    /// Where this actor sits in the two-phase admission of ADR 0005.
    phase: SocketPhase,
    /// The supervisor that starts topic workers for a socket actor.
    ///
    /// `beryl/channel` uses this supervisor for one process per accepted
    /// topic. Raw dispatch does not use it because its model contains all
    /// topics for one socket. The socket actor starts and links the
    /// supervisor. Thus, the workers stop with the socket. Joins on different
    /// sockets do not wait for each other.
    workers: Option(TopicWorkers),
  )
}

/// The admission phase of a socket actor (ADR 0005).
///
/// Phase one of admission starts the actor under the socket factory and
/// returns before any application callback runs, so the actor is `Booting`.
/// Phase two runs the application `init` from the router's `AdmitSocket`
/// and moves the actor to `Active`. `Closing` covers teardown, where no
/// admission may still be accepted.
type SocketPhase {
  Booting
  Active
  Closing
}

/// One topic worker a socket owns.
type WorkerRef {
  WorkerRef(subject: Subject(WorkerMessage), pid: Pid, monitor: process.Monitor)
}

// ── Suspended per-socket work ───────────────────────────────────────────────
//
// Presence mutations are asynchronous. The runtime must still apply an effect
// list in order and finish topic cleanup before it sends the terminal frame.
// A stack of `Step` values stores the remaining work. The interpreter runs
// steps until the stack is empty or a step needs a presence acknowledgment.
// It then stores the remaining stack in `State.suspended`. The runtime resumes
// that stack after the acknowledgment or timeout. Other sockets, broadcasts,
// and heartbeats continue.

/// A socket parked on one asynchronous operation.
type Suspension(message) {
  Suspension(
    waiting: Waiting,
    /// Cancelled when the operation completes in time.
    timer: process.Timer,
    /// Work to resume, in order, after the operation completes.
    stack: List(Step(message)),
  )
}

/// What a parked socket is waiting for.
type Waiting {
  /// A presence mutation's acknowledgement.
  PresenceWait(operation_id: Int, operation: PresenceOperation)
  /// Wait for a closing topic worker to report its termination.
  ///
  /// The runtime first applies the worker results that are in flight. It then
  /// continues the close from `execute_close_topic`.
  WorkerWait(
    topic: String,
    worker: WorkerRef,
    close_join_ref: Option(String),
    reason: StopReason,
    continuation: Continuation,
  )
}

/// The presence mutation a socket is waiting for, and everything needed to
/// finish it once it is acknowledged (or given up on).
type PresenceOperation {
  /// A `PresenceTrack`. The ref and stored meta only exist once the actor
  /// replies, so both the socket's ref map and the join diff are written
  /// from the acknowledgement. `replaced` is the previous entry for the
  /// same key, broadcast as the leave half of the replacement.
  TrackOperation(
    topic: String,
    key: String,
    replaced: List(presence.PresenceEntry),
  )
  /// A `PresenceUntrack` (`automatic: False`) or the automatic cleanup of
  /// a closing topic (`automatic: True`). The leaves are already known
  /// from the runtime's own ref map; only the broadcast waits.
  UntrackOperation(
    topic: String,
    leaves: List(presence.PresenceEntry),
    automatic: Bool,
  )
}

/// One resumable unit of per-socket work.
type Step(message) {
  /// Apply the remaining effects of one update's effect list.
  StepEffects(
    effects: List(Effect),
    pending: Option(Pending),
    kicks: List(String),
    continuation: Continuation,
  )
  /// Deliver one input to the app's `update` and apply what it returns.
  StepInput(input: Input(message), source: Source, continuation: Continuation)
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
  StepCloseTopic(topic: String, reason: StopReason, continuation: Continuation)
  /// Auto-untrack whatever presence the closing topic still holds.
  StepCloseCleanup(
    topic: String,
    close_join_ref: Option(String),
    reason: StopReason,
    kicks: List(String),
    stop: Option(StopReason),
    continuation: Continuation,
  )
  /// Send the closing topic's terminal frame, then hand its outcome on.
  StepCloseFinish(
    topic: String,
    close_join_ref: Option(String),
    reason: StopReason,
    kicks: List(String),
    stop: Option(StopReason),
    continuation: Continuation,
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
  /// Apply one callback result reported by a topic worker.
  StepWorkerReport(topic: String, report: WorkerReport)
}

/// What to do with the kicks and stop an effect list or topic close
/// produced. This is the reified "return address" of a step.
type Continuation {
  /// Drive them as ordinary update follow-ups.
  ContinueDriving
  /// Append them to a kick queue already in progress, then drive.
  ContinueKicks(rest: List(String))
  /// Continue the enclosing topic close: cleanup, then terminal frame.
  ContinueClosingTopic(
    topic: String,
    close_join_ref: Option(String),
    reason: StopReason,
    outer: Continuation,
  )
  /// Discard them (a teardown is already in progress) and close the next
  /// topic of that teardown.
  ContinueTeardownTopics(topics: List(String), reason: StopReason)
  /// Emit an update's terminal telemetry before continuing its caller.
  ContinueFinishingUpdate(
    source: Source,
    effects: List(Effect),
    outer: Continuation,
  )
}

/// The result of executing one step.
type Execution(model, message) {
  /// Continue immediately with `steps` pushed onto the stack.
  Continue(state: State(model, message), steps: List(Step(message)))
  /// Park the socket until `waiting` completes, then resume with `steps`
  /// pushed onto the stack.
  Await(
    state: State(model, message),
    waiting: Waiting,
    timer: process.Timer,
    steps: List(Step(message)),
  )
}

type SocketState(model, message) {
  SocketState(
    id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    close: fn() -> Nil,
    codec: Codec,
    /// Request data from the transport. Each topic worker receives it in
    /// `join`. Raw dispatch gives it to `init` and does not store it.
    seed: ConnectSeed,
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
    /// The worker for each joined topic when the layer uses one process per
    /// topic. The runtime removes it when the topic starts to close.
    workers: Dict(String, WorkerRef),
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
    message_ref: Option(String),
    ref: JoinRef,
  )
}

/// Where an event delivered to `update` (or cast to a topic worker) came
/// from, for crash attribution and telemetry.
pub type Source {
  JoinSource(
    topic: String,
    join_ref: Option(String),
    message_ref: Option(String),
    ref: JoinRef,
    started_at: Int,
  )
  MessageSource(topic: String, kind: telemetry.MessageKind, started_at: Int)
  InfoSource(started_at: Int)
  ClosedSource
}

/// Start runtime telemetry without touching the VM clock when disabled.
fn telemetry_start(state: State(model, message)) -> Int {
  start_time_if(state.config.telemetry)
}

fn start_time_if(enabled: Bool) -> Int {
  use <- bool.guard(when: !enabled, return: 0)
  telemetry.start_time()
}

fn emit_join_stop(
  state: State(model, message),
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
  state: State(model, message),
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

fn stop_reason_to_disconnect_reason(
  reason: StopReason,
) -> telemetry.DisconnectReason {
  case reason {
    socket.Normal -> telemetry.NormalDisconnect
    socket.Shutdown -> telemetry.ShutdownDisconnect
    socket.HeartbeatTimeout -> telemetry.HeartbeatTimeout
    socket.Errored(_) -> telemetry.CallbackDisconnect
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
  name name: process.Name(Message(message)),
  pubsub pubsub_option: Option(PubSub(Json)),
  init init: fn(ConnectInfo(message)) -> #(model, List(Effect)),
  update update: fn(model, Input(message)) -> Next(model),
) -> Result(actor.Started(Subject(Message(message))), actor.StartError) {
  internal.configure(config.logging)

  actor.new_with_initialiser(5000, fn(subject) {
    // Presence acknowledgements arrive on their own subject (the presence
    // actor knows nothing about `Message(message)`) and are folded into the
    // actor's selector.
    let acknowledgement_subject = process.new_subject()
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
        presence_acknowledgement: acknowledgement_subject,
        next_operation_id: 1,
        suspended: dict.new(),
        queued: dict.new(),
        unacknowledged_tracks: dict.new(),
        stopping: False,
        role: RouterRole(
          socket_actors: dict.new(),
          stop_reply: None,
          stop_finalized: 0,
        ),
      )
    // Heartbeats are per-socket timers, so the router runs no sweep and
    // schedules nothing.
    //
    // `select_monitors` claims every monitor `Down` this process receives,
    // so the router turn must never create a monitor for anything but a
    // socket actor — which the no-blocking-call rule (no `process.call`
    // from the router) already guarantees.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(acknowledgement_subject, PresenceAcknowledged)
      |> process.select_monitors(SocketActorDown)
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

/// The socket factory's message type, used only as the payload of its
/// registered name. The per-connection start argument is the router pid the
/// transport captured before admission.
pub type SocketFactoryMessage(message) =
  factory_supervisor.Message(process.Pid, Subject(Message(message)))

/// Build the socket factory child of the nested beryl supervisor (ADR 0005).
///
/// The factory is one `simple_one_for_one` supervisor for the whole system.
/// Its child template captures the runtime configuration, the application
/// `init` and `update`, and the optional topic-worker opener, so the only
/// per-connection argument is the captured router pid. Socket actors are
/// `Temporary`: a socket owns connection state that no supervisor can
/// reconstruct, so a stopped socket is recovered by a client reconnect.
///
/// The template runs no application callback. It starts the actor, which
/// runs `init` later, from the router's `AdmitSocket`.
pub fn socket_factory_child(
  config config: Config,
  init init: fn(ConnectInfo(message)) -> #(model, List(Effect)),
  update update: fn(model, Input(message)) -> Next(model),
  open_worker open_worker: Option(WorkerOpener),
  router router: Subject(Message(message)),
  name name: process.Name(SocketFactoryMessage(message)),
) -> supervision.ChildSpecification(
  factory_supervisor.Supervisor(process.Pid, Subject(Message(message))),
) {
  factory_supervisor.worker_child(fn(router_pid) {
    start_socket_actor(
      config:,
      init:,
      update:,
      open_worker:,
      router:,
      router_pid:,
    )
  })
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  |> factory_supervisor.named(name)
  |> factory_supervisor.supervised
}

/// Start one socket actor as a `Temporary` child of the named socket factory.
///
/// Called from the transport's connection process (through `beryl`'s
/// admission closure), so connection setup stays parallel and the router's
/// admission turn stays O(1). The factory is reached through its registered
/// name rather than a captured pid, so a restarted factory is used without
/// the caller holding a stale reference. If no factory is registered — before
/// startup, during a factory restart window, or after shutdown — this reports
/// the failure instead of crashing the transport process.
pub fn start_socket_child(
  factory factory: process.Name(SocketFactoryMessage(message)),
  router_pid router_pid: process.Pid,
) -> Result(actor.Started(Subject(Message(message))), actor.StartError) {
  case
    internal.rescue(fn() {
      factory_supervisor.start_child(
        factory_supervisor.get_by_name(factory),
        router_pid,
      )
    })
  {
    Ok(result) -> result
    Error(crash) -> Error(actor.InitFailed(crash))
  }
}

/// Start one actor to own one socket.
///
/// It runs the same `handle_message` on the same `State` as the router —
/// the socket actor is the router with `sockets` capped at one entry, no
/// topic index beyond its own memberships, no PubSub subscriber, and
/// `router` set. That is the whole lift of `dispatch_socket_msg`.
///
/// This is phase one of admission: it starts the actor and its per-socket
/// topic-worker factory and returns. It runs no application callback, so a
/// slow `init` never holds the socket factory's start turn.
fn start_socket_actor(
  config config: Config,
  init init: fn(ConnectInfo(message)) -> #(model, List(Effect)),
  update update: fn(model, Input(message)) -> Next(model),
  open_worker open_worker: Option(WorkerOpener),
  router router: Subject(Message(message)),
  router_pid router_pid: process.Pid,
) -> Result(actor.Started(Subject(Message(message))), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    let acknowledgement_subject = process.new_subject()
    // Start topic workers under a factory supervisor that links to this
    // actor. A worker crash does not stop the socket, but all workers stop
    // with the socket.
    use workers <- result.try(case open_worker {
      None -> Ok(None)
      Some(opener) ->
        factory_supervisor.worker_child(fn(spawn) {
          start_worker(opener.open, subject, config.telemetry, spawn)
        })
        |> factory_supervisor.restart_strategy(supervision.Temporary)
        |> factory_supervisor.start
        |> result.map(fn(started) {
          Some(TopicWorkers(accepts: opener.accepts, factory: started.data))
        })
        |> result.map_error(fn(error) {
          error
          |> beryl_error.from_actor_start_error
          |> beryl_error.describe_start_failure
        })
    })
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
        presence_acknowledgement: acknowledgement_subject,
        next_operation_id: 1,
        suspended: dict.new(),
        queued: dict.new(),
        unacknowledged_tracks: dict.new(),
        stopping: False,
        role: SocketActorRole(router:, phase: Booting, workers:),
      )
    // Router death must take its socket actors with it: each actor
    // monitors the router and stops on its `Down`, while a socket crash
    // reaches the router through the router's own monitor instead of a
    // link.
    let monitor = process.monitor(router_pid)
    schedule_heartbeat_check(subject, config)
    schedule_boot_check(subject)
    // Match the router monitor before the general monitor handler. Each other
    // `Down` message belongs to a topic worker for this socket.
    process.new_selector()
    |> process.select(subject)
    |> process.select_map(acknowledgement_subject, PresenceAcknowledged)
    |> process.select_specific_monitor(monitor, fn(_) { RouterDown })
    |> process.select_monitors(WorkerDown)
    |> actor.selecting(actor.returning(actor.initialised(state), subject), _)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Check at half the staleness window; `beryl.validate_config` guarantees the
/// timeout is at least 2, so the interval is always positive.
fn schedule_heartbeat_check(
  subject: Subject(Message(message)),
  config: Config,
) -> Nil {
  let _timer =
    process.send_after(
      subject,
      config.heartbeat_timeout_ms / 2,
      CheckHeartbeats,
    )
  Nil
}

/// How long a socket actor may stay in `Booting` before it gives up.
///
/// The transport waits one second for admission and then cancels it, so an
/// actor that is still unadmitted well past that has lost its transport: the
/// connection process died before it reached the router, or its cancellation
/// never arrived. The deadline is only read between turns, so it never cuts a
/// slow application `init` short.
const socket_boot_timeout_ms = 5000

fn schedule_boot_check(subject: Subject(Message(message))) -> Nil {
  let _timer = process.send_after(subject, socket_boot_timeout_ms, BootTimedOut)
  Nil
}

fn handle_message(
  state: State(model, message),
  message: Message(message),
) -> actor.Next(State(model, message), Message(message)) {
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
    | AppInfo(socket_id, _)
    | WorkerReport(socket_id, _, _, _)
    | WorkerTerminateTimedOut(socket_id, _) ->
      case state.role {
        // The router stays on the inbound path, one send per message: its
        // turn is a match-and-forward, never an app callback.
        RouterRole(socket_actors:, ..) -> {
          case dict.get(socket_actors, socket_id) {
            Ok(ref) -> process.send(ref.subject, message)
            Error(Nil) -> Nil
          }
          actor.continue(state)
        }
        SocketActorRole(..) -> socket_turn(state, socket_id, message)
      }
    // Only socket actors monitor workers, and each owns exactly one socket.
    WorkerDown(_) ->
      case state.role {
        RouterRole(..) -> actor.continue(state)
        SocketActorRole(..) ->
          case dict.keys(state.sockets) {
            [socket_id] -> socket_turn(state, socket_id, message)
            _ -> actor.continue(state)
          }
      }
    Broadcast(topic_name, event_name, payload, except) -> {
      case state.role {
        // In a socket actor this is a delivery, not an origination: the
        // router already resolved the recipients (decision 1's hop) and
        // this actor encodes and sends for its own socket.
        SocketActorRole(..) -> {
          let _recipient_count =
            local_broadcast(state, topic_name, event_name, payload, except)
          Nil
        }
        RouterRole(..) ->
          broadcast_with_pubsub(state, topic_name, event_name, payload, except)
      }
      actor.continue(state)
    }
    RemoteBroadcast(pubsub_message) ->
      // Crash boundary — see internal.rescue. The payload's own shape is a
      // frozen wire contract; drop malformed frames from mismatched peers.
      case
        internal.rescue(fn() { handle_remote_broadcast(state, pubsub_message) })
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
    PresenceAcknowledged(acknowledgement) ->
      after_socket_turn(
        state,
        handle_presence_acknowledgement(state, acknowledgement),
      )
    PresenceOperationTimedOut(socket_id, operation_id) ->
      after_socket_turn(
        state,
        handle_presence_timeout(state, socket_id, operation_id),
      )
    GetStats(reply) -> {
      // Answered entirely from the router's index; no socket actor is
      // polled, so counts may lag in-flight socket lifecycle messages —
      // the eventual consistency the stats API documents.
      let connected_sockets = case state.role {
        RouterRole(socket_actors:, ..) -> dict.size(socket_actors)
        SocketActorRole(..) -> 0
      }
      process.send(
        reply,
        StatsSnapshot(
          connected_sockets: connected_sockets,
          joined_socket_topic_pairs: state.topics
            |> dict.values
            |> list.fold(0, fn(total, ids) { total + set.size(ids) }),
          active_topics: dict.size(state.topics),
        ),
      )
      actor.continue(state)
    }
    Stop(reply) ->
      case state.role {
        SocketActorRole(..) -> handle_stop(state, Some(reply))
        RouterRole(..) -> begin_router_stop(state, reply)
      }
    FinalizeForStop -> {
      let state = finalize_for_stop(state)
      case state.role {
        SocketActorRole(router:, ..) -> process.send(router, StopPhaseDone)
        RouterRole(..) -> Nil
      }
      actor.continue(state)
    }
    StopPhaseDone ->
      case state.role {
        RouterRole(socket_actors:, stop_reply:, stop_finalized:) -> {
          let state =
            State(
              ..state,
              role: RouterRole(
                socket_actors: socket_actors,
                stop_reply: stop_reply,
                stop_finalized: stop_finalized + 1,
              ),
            )
          begin_stop_phase_two_if_ready(state)
          actor.continue(state)
        }
        SocketActorRole(..) -> actor.continue(state)
      }
    StopSocketActor -> {
      // The router is waiting on `SocketClosed`, not on a reply, so the
      // teardown's own broadcasts reach it before the actor goes away.
      let socket_ids = dict.keys(state.sockets)
      let next = handle_stop(state, None)
      case state.role {
        RouterRole(..) -> Nil
        SocketActorRole(router:, ..) ->
          case socket_ids {
            [socket_id] -> process.send(router, SocketClosed(socket_id))
            _ -> Nil
          }
      }
      next
    }
    StopTimedOut ->
      case state.role {
        RouterRole(stop_reply: None, ..) | SocketActorRole(..) ->
          actor.continue(state)
        RouterRole(socket_actors:, stop_reply: Some(reply), ..) -> {
          // Escalate rather than abandon: a teardown stuck in a
          // pathological app callback is killed so shutdown stays inside
          // `beryl.stop`'s budget without leaking the process.
          state.logger
          |> log.warn("Runtime stop: killing unresponsive socket actors", [
            #("socket_count", int.to_string(dict.size(socket_actors))),
          ])
          dict.values(socket_actors)
          |> list.each(fn(ref) { process.kill(ref.pid) })
          process.send(reply, app_supervisor.StopIncomplete)
          actor.stop()
        }
      }
    IndexJoin(socket_id, topic_name) ->
      // Only index sockets this router admitted: a cast from an actor that
      // outlived a router restart must not plant a phantom entry. A
      // legitimate join is always preceded by the router's own insert, so
      // this never drops a real one.
      case state.role {
        RouterRole(socket_actors:, ..) ->
          case dict.has_key(socket_actors, socket_id) {
            True ->
              actor.continue(add_topic_subscriber(state, socket_id, topic_name))
            False -> actor.continue(state)
          }
        SocketActorRole(..) -> actor.continue(state)
      }
    IndexLeave(socket_id, topic_name) ->
      actor.continue(remove_topic_subscriber(state, socket_id, topic_name))
    SocketClosed(socket_id) -> remove_socket_actor(state, socket_id)
    SocketActorDown(down) ->
      case state.role {
        SocketActorRole(..) -> actor.continue(state)
        RouterRole(socket_actors:, ..) ->
          handle_router_socket_actor_down(state, down, socket_actors)
      }
    RouterDown -> actor.stop()
    BootTimedOut ->
      case state.role {
        SocketActorRole(phase: Booting, ..) -> {
          state.logger
          |> log.warn("Socket actor stopping: never admitted", [])
          actor.stop()
        }
        SocketActorRole(phase: Active, ..)
        | SocketActorRole(phase: Closing, ..)
        | RouterRole(..) -> actor.continue(state)
      }
  }
}

fn handle_router_socket_actor_down(
  state: State(model, message),
  down: process.Down,
  socket_actors: Dict(String, SocketActorRef(message)),
) -> actor.Next(State(model, message), Message(message)) {
  case down {
    process.ProcessDown(pid: pid, monitor: _, reason: _) ->
      case
        dict.to_list(socket_actors)
        |> list.find(fn(entry) {
          let #(_, ref) = entry
          ref.pid == pid
        })
      {
        Ok(#(socket_id, ref)) -> {
          state.logger
          |> log.warn("Socket actor exited without reporting; sweeping", [
            #("socket_id", socket_id),
          ])
          let _closer = process.spawn_unlinked(ref.close)
          case state.config.presence {
            Some(handle) ->
              presence.untrack_runtime_all_async(handle, socket_id)
            None -> Nil
          }
          remove_socket_actor(state, socket_id)
        }
        // Already removed via `SocketClosed`, or never admitted.
        Error(Nil) -> actor.continue(state)
      }
    process.PortDown(..) -> actor.continue(state)
  }
}

/// Drop one socket actor from the router: demonitor, sweep any topic-index
/// entries it left behind, and keep a stop drain moving if one is in
/// progress. Shared by the normal close (`SocketClosed`) and the crash
/// sweep (`SocketActorDown`).
fn remove_socket_actor(
  state: State(model, message),
  socket_id: String,
) -> actor.Next(State(model, message), Message(message)) {
  case state.role {
    SocketActorRole(..) -> actor.continue(state)
    RouterRole(socket_actors:, stop_reply:, stop_finalized:) -> {
      case dict.get(socket_actors, socket_id) {
        // Demonitoring flushes a `Down` already in the mailbox, so a normal
        // close can never be swept a second time as a crash.
        Ok(ref) -> process.demonitor_process(ref.monitor)
        Error(Nil) -> Nil
      }
      // A teardown emits `IndexLeave` per joined topic, but sweeping is
      // cheap and makes a dropped one impossible to leak.
      let state =
        dict.keys(state.topics)
        |> list.fold(state, fn(st, topic_name) {
          remove_topic_subscriber(st, socket_id, topic_name)
        })
      let socket_actors = dict.delete(socket_actors, socket_id)
      let state =
        State(
          ..state,
          role: RouterRole(
            socket_actors: socket_actors,
            stop_reply: stop_reply,
            stop_finalized: stop_finalized,
          ),
        )
      case stop_reply, dict.is_empty(socket_actors) {
        None, True | None, False -> actor.continue(state)
        Some(reply), True -> {
          process.send(reply, app_supervisor.StopCompleted)
          actor.stop()
        }
        Some(_), False -> {
          // A crash during drain phase one would otherwise leave the router
          // waiting on a `StopPhaseDone` that never arrives.
          begin_stop_phase_two_if_ready(state)
          actor.continue(state)
        }
      }
    }
  }
}

/// Start drain phase two once every surviving socket actor has finished
/// phase one. Re-sending `StopSocketActor` to an actor that already got
/// one is harmless: it stops on the first and never reads the second.
fn begin_stop_phase_two_if_ready(state: State(model, message)) -> Nil {
  case state.role {
    SocketActorRole(..) -> Nil
    RouterRole(socket_actors:, stop_finalized:, ..) ->
      case stop_finalized >= dict.size(socket_actors) {
        True ->
          dict.values(socket_actors)
          |> list.each(fn(ref) { process.send(ref.subject, StopSocketActor) })
        False -> Nil
      }
  }
}

/// Run one socket-scoped message in a socket actor.
///
/// A suspended socket queues its messages instead of dispatching them. This
/// preserves input order. The event that ends the suspension is the only
/// exception.
fn socket_turn(
  state: State(model, message),
  socket_id: String,
  message: Message(message),
) -> actor.Next(State(model, message), Message(message)) {
  case dict.get(state.suspended, socket_id) {
    Error(Nil) ->
      after_socket_turn(state, dispatch_socket_msg(state, socket_id, message))
    Ok(suspension) ->
      case resume_worker_close(state, socket_id, suspension, message) {
        Some(after) -> after_socket_turn(state, after)
        None -> actor.continue(enqueue_socket_msg(state, socket_id, message))
      }
  }
}

/// A socket actor's turn is over. If the socket is gone the actor has
/// nothing left to own, so it tells the router and stops.
fn after_socket_turn(
  before: State(model, message),
  after: State(model, message),
) -> actor.Next(State(model, message), Message(message)) {
  case after.role {
    RouterRole(..) -> actor.continue(after)
    SocketActorRole(router:, ..) ->
      case dict.keys(before.sockets) {
        [socket_id] ->
          case dict.has_key(after.sockets, socket_id) {
            True -> actor.continue(after)
            False -> {
              process.send(router, SocketClosed(socket_id))
              actor.stop()
            }
          }
        _ -> actor.continue(after)
      }
  }
}

/// Dispatch one socket-scoped message. Called directly when the socket is
/// running and from `drain_queue` for messages that arrived while it was
/// suspended, so both paths share exactly one implementation.
fn dispatch_socket_msg(
  state: State(model, message),
  socket_id: String,
  message: Message(message),
) -> State(model, message) {
  case message {
    SocketDisconnected(socket_id) ->
      handle_socket_disconnected(state, socket_id)
    RouteText(socket_id, raw_text) ->
      handle_route_text(state, socket_id, raw_text)
    RouteDecoded(socket_id, message) ->
      dispatch_inbound(state, socket_id, message, telemetry.TextMessage)
    RouteDecodedBinary(socket_id, message) ->
      dispatch_inbound(state, socket_id, message, telemetry.BinaryMessage)
    HandleBinary(socket_id, data) -> handle_binary_in(state, socket_id, data)
    AppInfo(socket_id, app_message) ->
      handle_app_info(state, socket_id, app_message)
    WorkerReport(socket_id, topic_name, pid, report) ->
      handle_worker_report(state, socket_id, topic_name, pid, report)
    WorkerDown(down) -> handle_worker_down(state, socket_id, down)
    // Only meaningful while its socket is parked on that worker, which
    // `socket_turn` handles before dispatch; anything else is a late timer.
    WorkerTerminateTimedOut(..) -> state
    // Not socket-scoped, so never deferred to this dispatcher.
    AdmitSocket(..)
    | Broadcast(..)
    | RemoteBroadcast(..)
    | CheckHeartbeats
    | GetStats(..)
    | PresenceAcknowledged(..)
    | PresenceOperationTimedOut(..)
    | Stop(..)
    | StopSocketActor
    | StopTimedOut
    | FinalizeForStop
    | StopPhaseDone
    | IndexJoin(..)
    | IndexLeave(..)
    | SocketClosed(..)
    | SocketActorDown(..)
    | RouterDown
    | BootTimedOut -> state
  }
}

/// Defer a socket-scoped message until its socket resumes. The queue is
/// stored newest-first and reversed once per drain, so queueing stays O(1)
/// per message even under a flood.
fn enqueue_socket_msg(
  state: State(model, message),
  socket_id: String,
  message: Message(message),
) -> State(model, message) {
  let queue =
    dict.get(state.queued, socket_id)
    |> result.unwrap([])
  state.logger
  |> log.debug("Socket message queued: socket parked", [
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
  state: State(model, message),
  socket_id: String,
) -> State(model, message) {
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
  state: State(model, message),
  socket_id: String,
  messages: List(Message(message)),
) -> State(model, message) {
  case messages {
    [] -> state
    [message, ..rest] -> {
      let state = dispatch_socket_msg(state, socket_id, message)
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
  state: State(model, message),
  owner: process.Pid,
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  socket_codec: Option(Codec),
  seed: ConnectSeed,
  close: fn() -> Nil,
  admission: AdmissionToken,
  reply: Subject(Bool),
  actor_subject: Subject(Message(message)),
  actor_pid: process.Pid,
) -> actor.Next(State(model, message), Message(message)) {
  case state.role {
    // Phase two of admission (ADR 0005). The router has already admitted
    // this socket atomically in its own turn; this actor runs the app
    // `init` and answers the transport directly.
    SocketActorRole(router:, phase: Booting, workers:) -> {
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
        True ->
          actor.continue(
            State(
              ..state,
              role: SocketActorRole(router:, phase: Active, workers:),
            ),
          )
        // Refused: the app `init` crashed, or the transport's wait timed
        // out and cancelled the token. The router already indexed this
        // actor, so unwind that entry on the way out.
        False -> {
          process.send(router, SocketClosed(socket_id))
          actor.stop()
        }
      }
    }
    // A second admission for an actor that is already admitted or already
    // tearing down. Only one socket may ever register per actor, so this
    // is refused without running `init` again.
    SocketActorRole(phase: Active, ..) | SocketActorRole(phase: Closing, ..) -> {
      process.send(reply, False)
      actor.continue(state)
    }
    // The router's whole admission turn: the checks that must be atomic
    // with each other, one monitor-free insert, and a forward. It never
    // waits on the socket actor — the actor answers the transport itself,
    // so a slow or crashing `init` cannot block admission of other
    // sockets (and the router must never block on a socket actor).
    RouterRole(socket_actors:, stop_reply:, stop_finalized:) ->
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
          // Monitor before forwarding: an actor that dies mid-registration
          // is swept by `SocketActorDown` instead of leaking its entry.
          let monitor = process.monitor(actor_pid)
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
              role: RouterRole(
                socket_actors: dict.insert(
                  socket_actors,
                  socket_id,
                  SocketActorRef(actor_subject, actor_pid, monitor, close),
                ),
                stop_reply: stop_reply,
                stop_finalized: stop_finalized,
              ),
            ),
          )
        }
      }
  }
}

fn register_socket(
  state: State(model, message),
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  socket_codec: Option(Codec),
  seed: ConnectSeed,
  close: fn() -> Nil,
  admission: Option(AdmissionToken),
) -> #(State(model, message), Bool) {
  use <- bool.guard(when: !admission_is_pending(admission), return: #(
    state,
    False,
  ))
  let sender = make_socket_sender(state, socket_id)
  let info = socket.ConnectInfo(socket_id: socket_id, seed: seed, self: sender)
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
          seed: case state.role {
            SocketActorRole(workers: Some(_), ..) -> seed
            SocketActorRole(workers: None, ..) | RouterRole(..) ->
              socket.empty_seed()
          },
          model: model,
          subscribed_topics: set.new(),
          join_refs: dict.new(),
          presence_refs: dict.new(),
          pending_reply_refs: set.new(),
          workers: dict.new(),
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
  state: State(model, message),
  socket_id: String,
  effects: List(Effect),
) -> State(model, message) {
  run(state, socket_id, [StepEffects(effects, None, [], ContinueDriving)])
}

/// Build the typed `Sender` for a socket. The closure sends through the
/// runtime's own mailbox — an ordinary typed send, usable from any process.
fn make_socket_sender(
  state: State(model, message),
  socket_id: String,
) -> socket.Sender(message) {
  let subject = state.self_subject
  socket.make_sender(fn(message) {
    process.send(subject, AppInfo(socket_id, message))
  })
}

fn handle_socket_disconnected(
  state: State(model, message),
  socket_id: String,
) -> State(model, message) {
  let metadata = case dict.get(state.sockets, socket_id) {
    Ok(socket) ->
      list.append([#("socket_id", socket_id)], joined_topics_metadata(socket))
    Error(Nil) -> [#("socket_id", socket_id)]
  }
  state.logger |> log.info("Socket disconnected", metadata)
  run(state, socket_id, [StepTeardown(socket.Normal)])
}

/// How long the router waits for its socket actors to drain before it
/// kills the stragglers, chosen to sit inside `beryl.stop`'s own 5s
/// budget. Crashed actors report promptly through their monitors, so this
/// only fires for a teardown genuinely stuck in an app callback.
const stop_drain_timeout_ms = 2000

/// Drain the socket actors, then stop.
///
/// The router casts `StopSocketActor` rather than calling, so a socket
/// actor's teardown broadcasts and index updates still route through this
/// mailbox. The router answers `reply` once the last `SocketClosed` lands,
/// or kills the survivors at `stop_drain_timeout_ms`.
fn begin_router_stop(
  state: State(model, message),
  reply: Subject(app_supervisor.StopCompletion),
) -> actor.Next(State(model, message), Message(message)) {
  case state.role {
    SocketActorRole(..) -> handle_stop(state, Some(reply))
    RouterRole(socket_actors:, stop_finalized:, ..) -> {
      state.logger
      |> log.info("Runtime stopping", [
        #("socket_count", int.to_string(dict.size(socket_actors))),
      ])
      use <- bool.lazy_guard(when: dict.is_empty(socket_actors), return: fn() {
        process.send(reply, app_supervisor.StopCompleted)
        actor.stop()
      })
      dict.values(socket_actors)
      |> list.each(fn(ref) { process.send(ref.subject, FinalizeForStop) })
      let _timer =
        process.send_after(
          state.self_subject,
          stop_drain_timeout_ms,
          StopTimedOut,
        )
      actor.continue(
        State(
          ..state,
          stopping: True,
          role: RouterRole(
            socket_actors: socket_actors,
            stop_reply: Some(reply),
            stop_finalized: stop_finalized,
          ),
        ),
      )
    }
  }
}

fn handle_stop(
  state: State(model, message),
  reply: Option(Subject(app_supervisor.StopCompletion)),
) -> actor.Next(State(model, message), Message(message)) {
  state.logger
  |> log.info("Runtime stopping", [
    #("socket_count", int.to_string(dict.size(state.sockets))),
  ])
  let state = finalize_for_stop(state)
  dict.keys(state.sockets)
  |> list.fold(state, fn(st, socket_id) {
    run(st, socket_id, [StepTeardown(socket.Shutdown)])
  })
  case reply {
    Some(reply) -> process.send(reply, app_supervisor.StopCompleted)
    None -> Nil
  }
  actor.stop()
}

/// The pre-teardown half of a shutdown: mark the actor stopping and settle
/// every in-flight presence mutation it still owns.
///
/// The shared runtime ran this for all sockets before it tore any of them
/// down. Per-socket actors have to be told to do it as a separate phase,
/// or a socket's shutdown leaves can be fanned out to sockets that are
/// already gone.
fn finalize_for_stop(state: State(model, message)) -> State(model, message) {
  // From here on there is no runtime left to receive an acknowledgement,
  // so presence mutations are sent fire-and-forget and never suspend.
  let state = State(..state, stopping: True)
  // A socket actor is closing from here on, so a late `AdmitSocket` must
  // not run the application `init` behind the teardown.
  let state = case state.role {
    RouterRole(..) -> state
    SocketActorRole(router:, workers:, ..) ->
      State(..state, role: SocketActorRole(router:, phase: Closing, workers:))
  }
  let state =
    dict.keys(state.suspended)
    |> list.fold(state, finalize_suspension)
  // Tracks this runtime already gave up on can still be applied by the
  // presence actor, and their acknowledgements can no longer be
  // compensated once this actor stops — so their runtime-owned refs are
  // swept now, while there is still something to sweep them with. The sweep is
  // ordered behind the in-flight tracks themselves (same sender, same
  // mailbox), so it removes them rather than racing them.
  dict.keys(state.unacknowledged_tracks)
  |> list.fold(state, sweep_unacknowledged_track)
}

/// Finalize a socket's in-flight presence mutation during shutdown.
///
/// The runtime cannot wait for its acknowledgement, but it must still publish
/// the leave side of a pending replacement or untrack because those refs have
/// already left the socket's bookkeeping. The mutation is finalized through
/// the normal stopping path, then every runtime-owned ref for the socket is
/// swept behind the in-flight mutation in the presence actor's mailbox.
fn finalize_suspension(
  state: State(model, message),
  socket_id: String,
) -> State(model, message) {
  case dict.get(state.suspended, socket_id) {
    Error(Nil) -> state
    Ok(suspension) -> {
      let cancelled = process.cancel_timer(suspension.timer)
      let state =
        State(
          ..state,
          // The runtime-owned sweep below also removes anything an earlier,
          // already-timed-out track of this socket could still add.
          unacknowledged_tracks: dict.delete(
            state.unacknowledged_tracks,
            socket_id,
          ),
        )
      let state = case suspension.waiting {
        PresenceWait(operation:, ..) -> {
          state.logger
          |> log.warn("Presence operation finalized: runtime stopping", [
            #("socket_id", socket_id),
          ])
          let state =
            State(
              ..state,
              suspended: dict.delete(state.suspended, socket_id),
              queued: dict.delete(state.queued, socket_id),
            )
          finish_presence_operation(
            state,
            socket_id,
            operation,
            Error(PresenceStopping),
          )
        }
        // The worker is already running `on_terminate`. The socket sent the
        // request when it started to wait. Give the worker the remaining
        // time. Then apply its earlier results, answer the leave, and close
        // the topic. Do not handle other queued socket work because shutdown
        // stops the actor next.
        WorkerWait(worker:, ..) ->
          finalize_worker_wait(state, socket_id, suspension, worker, cancelled)
      }
      case state.config.presence {
        Some(handle) -> presence.untrack_runtime_all_async(handle, socket_id)
        None -> Nil
      }
      state
    }
  }
}

fn finalize_worker_wait(
  state: State(model, message),
  socket_id: String,
  suspension: Suspension(message),
  worker: WorkerRef,
  cancelled: process.Cancelled,
) -> State(model, message) {
  let budget = case cancelled {
    process.Cancelled(time_remaining:) -> time_remaining
    process.TimerNotFound -> 0
  }
  let in_flight =
    dict.get(state.queued, socket_id)
    |> result.unwrap([])
    |> list.filter(fn(message) {
      case message {
        WorkerReport(worker: pid, ..) -> pid == worker.pid
        AdmitSocket(..)
        | SocketDisconnected(..)
        | RouteText(..)
        | RouteDecoded(..)
        | RouteDecodedBinary(..)
        | HandleBinary(..)
        | AppInfo(..)
        | Broadcast(..)
        | RemoteBroadcast(..)
        | CheckHeartbeats
        | GetStats(..)
        | PresenceAcknowledged(..)
        | PresenceOperationTimedOut(..)
        | Stop(..)
        | IndexJoin(..)
        | IndexLeave(..)
        | SocketClosed(..)
        | RouterDown
        | SocketActorDown(..)
        | StopSocketActor
        | StopTimedOut
        | FinalizeForStop
        | StopPhaseDone
        | WorkerDown(..)
        | WorkerTerminateTimedOut(..)
        | BootTimedOut -> False
      }
    })
  let #(in_flight, message) =
    await_worker_terminated(
      state,
      socket_id,
      worker,
      in_flight,
      monotonic_time_ms() + budget,
    )
  let state =
    State(..state, queued: dict.insert(state.queued, socket_id, in_flight))
  resume_worker_close(state, socket_id, suspension, message)
  |> option.unwrap(state)
}

fn exit_reason_to_string(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(_) -> "abnormal"
  }
}

/// Wait until `deadline` for the worker of a stopping socket to terminate.
///
/// Read the termination message from this actor's mailbox. Keep earlier
/// worker results in newest-first order so the resumed close can apply them.
/// Drop all other messages because the actor is stopping. Return the message
/// that `resume_worker_close` needs to continue the close.
fn await_worker_terminated(
  state: State(model, message),
  socket_id: String,
  worker: WorkerRef,
  in_flight: List(Message(message)),
  deadline: Int,
) -> #(List(Message(message)), Message(message)) {
  let awaited = worker.pid
  let received =
    process.new_selector()
    |> process.select_map(state.self_subject, Ok)
    |> process.select_specific_monitor(worker.monitor, Error)
    |> process.selector_receive(int.max(0, deadline - monotonic_time_ms()))
  case received {
    Ok(Ok(WorkerReport(worker: pid, report:, ..) as message))
      if pid == awaited
    ->
      case report {
        WorkerTerminated(..) -> #(in_flight, message)
        WorkerRan(..) | WorkerCrashed(..) ->
          await_worker_terminated(
            state,
            socket_id,
            worker,
            [message, ..in_flight],
            deadline,
          )
      }
    Ok(Ok(_)) ->
      await_worker_terminated(state, socket_id, worker, in_flight, deadline)
    Ok(Error(down)) -> #(in_flight, WorkerDown(down))
    Error(Nil) -> #(in_flight, WorkerTerminateTimedOut(socket_id, awaited))
  }
}

/// Sweep a session whose earlier, timed-out track may still land at the
/// presence actor after this runtime is gone. Same reasoning as
/// `finalize_suspension`: the ref was never learned here, and after
/// shutdown never will be, so the session's runtime-owned refs are removed
/// instead of leaving an entry nothing can remove.
fn sweep_unacknowledged_track(
  state: State(model, message),
  socket_id: String,
) -> State(model, message) {
  state.logger
  |> log.warn("Presence track abandoned: runtime stopping", [
    #("socket_id", socket_id),
  ])
  case state.config.presence {
    Some(handle) -> presence.untrack_runtime_all_async(handle, socket_id)
    None -> Nil
  }
  State(
    ..state,
    unacknowledged_tracks: dict.delete(state.unacknowledged_tracks, socket_id),
  )
}

// ── Heartbeats ──────────────────────────────────────────────────────────────

fn handle_heartbeat(
  state: State(model, message),
  socket_id: String,
  ref: Option(String),
) -> State(model, message) {
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
        #("ref", option_to_log_string(ref)),
      ])
      state
    }
  }
}

fn handle_check_heartbeats(
  state: State(model, message),
) -> State(model, message) {
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
      run(st, socket_id, [StepTeardown(socket.HeartbeatTimeout)])
    })
  schedule_heartbeat_check(state.self_subject, state.config)
  state
}

// ── Inbound decoding and dispatch ───────────────────────────────────────────

fn handle_route_text(
  state: State(model, message),
  socket_id: String,
  raw_text: String,
) -> State(model, message) {
  let active_codec = case dict.get(state.sockets, socket_id) {
    Ok(socket) -> socket.codec
    Error(Nil) -> state.config.codec
  }
  let logging = state.config.logging
  case codec.decode_text(active_codec)(raw_text) {
    Error(error) -> {
      state.logger
      |> log.warn(
        "Failed to decode wire protocol message",
        list.append(
          [
            #("socket_id", socket_id),
            #("error", codec.format_decode_error(error)),
          ],
          internal.preview_metadata("frame_preview", raw_text, logging),
        ),
      )
      state
    }
    Ok(message) ->
      dispatch_inbound(state, socket_id, message, telemetry.TextMessage)
  }
}

fn dispatch_inbound(
  state: State(model, message),
  socket_id: String,
  message: codec.Inbound,
  message_kind: telemetry.MessageKind,
) -> State(model, message) {
  let message_topic = codec.inbound_topic(message)
  let message_ref = codec.inbound_ref(message)
  case codec.inbound_kind(message) {
    codec.Join -> {
      let started_at = telemetry_start(state)
      case
        is_valid_topic(message_topic, state.config)
        && !is_reserved_topic(message_topic)
      {
        True ->
          handle_join(
            state,
            socket_id,
            message_topic,
            codec.inbound_payload(message),
            codec.inbound_join_ref(message),
            message_ref,
            started_at,
          )
        False -> reject_invalid_join(state, socket_id, message, started_at)
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
      case is_valid_topic(message_topic, state.config) {
        False -> {
          state.logger
          |> log.warn("Leave dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", topic.sanitize_for_log(message_topic)),
          ])
          state
        }
        True ->
          handle_leave(
            state,
            socket_id,
            message_topic,
            codec.inbound_join_ref(message),
            message_ref,
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
      let state = handle_heartbeat(state, socket_id, message_ref)
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
            #("topic", topic.sanitize_for_log(message_topic)),
            #("event", topic.sanitize_for_log(event_name)),
          ]
        },
        started_at,
        message_kind,
      )
      let resolved = resolve_event_topic(state, socket_id, message_topic)
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
            codec.inbound_payload(message),
            codec.inbound_join_ref(message),
            message_ref,
            started_at,
            message_kind,
          )
        False, True | False, False -> {
          state.logger
          |> log.warn("Event dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", topic.sanitize_for_log(message_topic)),
            #("event", topic.sanitize_for_log(event_name)),
          ])
          state
        }
        True, False -> {
          state.logger
          |> log.warn("Event dropped: invalid event", [
            #("socket_id", socket_id),
            #("topic", message_topic),
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
  state: State(model, message),
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
            True, [] | True, [_, _, ..] | False, _ -> requested
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
  state: State(model, message),
  socket_id: String,
  metadata: fn() -> List(#(String, String)),
  started_at: Int,
  kind: telemetry.MessageKind,
  next: fn(State(model, message)) -> State(model, message),
) -> State(model, message) {
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
  state: State(model, message),
  socket_id: String,
  message: codec.Inbound,
  started_at: Int,
) -> State(model, message) {
  let safe_topic = topic.sanitize_for_log(codec.inbound_topic(message))
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
          codec.inbound_join_ref(message),
          codec.inbound_ref(message),
          codec.inbound_topic(message),
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
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> State(model, message) {
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
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> State(model, message) {
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
                StepCloseTopic(topic_name, socket.Normal, ContinueDriving),
                deliver,
              ])
            False -> run(state, socket_id, [deliver])
          }
        }
      }
  }
}

fn can_join_topic(
  socket: SocketState(model, message),
  topic_name: String,
  config: Config,
) -> Bool {
  config.max_joined_topics_per_socket <= 0
  || set.contains(socket.subscribed_topics, topic_name)
  || set.size(socket.subscribed_topics) < config.max_joined_topics_per_socket
}

// ── Leaves ──────────────────────────────────────────────────────────────────

fn handle_leave(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  message_join_ref: Option(String),
  ref: Option(String),
) -> State(model, message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> {
      use <- bool.lazy_guard(
        when: is_stale_join_ref(socket, topic_name, message_join_ref),
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
        Some(message_ref) -> {
          let reply =
            codec.encode_reply(socket.codec)(
              joined_ref(socket, topic_name),
              Some(message_ref),
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
        StepCloseTopic(topic_name, socket.Normal, ContinueDriving),
      ])
    }
  }
}

/// A message is stale when it carries a join_ref from a previous channel
/// instance on this topic (the client rejoined since sending it).
fn is_stale_join_ref(
  socket: SocketState(model, message),
  topic_name: String,
  message_join_ref: Option(String),
) -> Bool {
  case message_join_ref, joined_ref(socket, topic_name) {
    Some(sent), Some(current) -> sent != current
    Some(_), None | None, Some(_) | None, None -> False
  }
}

fn joined_ref(
  socket: SocketState(model, message),
  topic_name: String,
) -> Option(String) {
  dict.get(socket.join_refs, topic_name)
  |> result.unwrap(None)
}

// ── Client messages ─────────────────────────────────────────────────────────

fn handle_in_subscribed(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  message_join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, message) {
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
          case is_stale_join_ref(socket, topic_name, message_join_ref) {
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
  state: State(model, message),
  socket: SocketState(model, message),
  socket_id: String,
  topic_name: String,
  event_name: String,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, message) {
  state.logger
  |> log.debug("Inbound message rejected", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("event", event_name),
    #("reason", "topic_not_joined"),
  ])
  case ref {
    Some(message_ref) -> {
      let reply =
        codec.encode_reply(socket.codec)(
          None,
          Some(message_ref),
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
  state: State(model, message),
  socket: SocketState(model, message),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, message) {
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
  state: State(model, message),
  socket: SocketState(model, message),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, message) {
  state.logger
  |> log.debug("Inbound message routed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("event", event_name),
    #("ref", option_to_log_string(ref)),
  ])
  let message_ref =
    option.map(ref, fn(ref) {
      socket.make_message_ref(
        topic: topic_name,
        join_ref: joined_ref(socket, topic_name),
        message_ref: Some(ref),
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
  state: State(model, message),
  socket: SocketState(model, message),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  message_ref: ReplyRef,
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, message) {
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
        socket.reply_ref_join_ref(message_ref),
        socket.reply_ref_message_ref(message_ref),
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
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  event_name: String,
  payload: Dynamic,
  message_ref: Option(ReplyRef),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> State(model, message) {
  let state = case message_ref {
    Some(message_ref) -> register_reply_ref(state, socket_id, message_ref)
    None -> state
  }
  run(state, socket_id, [
    StepInput(
      socket.Message(
        topic: topic_name,
        event: event_name,
        payload: payload,
        ref: message_ref,
      ),
      MessageSource(topic_name, kind, started_at),
      ContinueDriving,
    ),
  ])
}

// ── Binary frames ───────────────────────────────────────────────────────────

fn handle_binary_in(
  state: State(model, message),
  socket_id: String,
  data: BitArray,
) -> State(model, message) {
  let active_codec = case dict.get(state.sockets, socket_id) {
    Ok(socket) -> socket.codec
    Error(Nil) -> state.config.codec
  }
  case codec.decode_binary(active_codec) {
    Some(decode_binary) ->
      case decode_binary(data) {
        Error(error) -> {
          state.logger
          |> log.warn("Failed to decode binary wire protocol message", [
            #("socket_id", socket_id),
            #("error", codec.format_decode_error(error)),
          ])
          state
        }
        Ok(message) ->
          dispatch_inbound(state, socket_id, message, telemetry.BinaryMessage)
      }
    None -> handle_undecoded_binary_in(state, socket_id, data)
  }
}

/// Rate-limit and fan an undecoded binary frame out to each joined topic.
/// The frame keeps binary telemetry classification; attacker-driven drops
/// log at debug to avoid warning-level amplification.
fn handle_undecoded_binary_in(
  state: State(model, message),
  socket_id: String,
  data: BitArray,
) -> State(model, message) {
  let started_at = telemetry_start(state)
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed, dict.get(state.sockets, socket_id) {
    False, Ok(_) | False, Error(Nil) -> {
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
  state: State(model, message),
  socket_id: String,
  message: message,
) -> State(model, message) {
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
        StepInput(socket.Info(message), InfoSource(started_at), ContinueDriving),
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
  state: State(model, message),
  socket_id: String,
  stack: List(Step(message)),
) -> State(model, message) {
  case stack {
    [] -> state
    [step, ..rest] ->
      case execute_step(state, socket_id, step) {
        Continue(state, steps) ->
          run(state, socket_id, list.append(steps, rest))
        Await(state, waiting, timer, steps) ->
          State(
            ..state,
            suspended: dict.insert(
              state.suspended,
              socket_id,
              Suspension(
                waiting: waiting,
                timer: timer,
                stack: list.append(steps, rest),
              ),
            ),
          )
      }
  }
}

fn execute_step(
  state: State(model, message),
  socket_id: String,
  step: Step(message),
) -> Execution(model, message) {
  case step {
    StepEffects(effects, pending, kicks, continuation) ->
      run_effects(state, socket_id, effects, pending, kicks, continuation)
    StepInput(input, source, continuation) ->
      execute_input(state, socket_id, input, source, continuation)
    StepDeliverJoin(topic_name, payload, join_ref, ref, started_at) ->
      execute_deliver_join(
        state,
        socket_id,
        topic_name,
        payload,
        join_ref,
        ref,
        started_at,
      )
    StepBinaryTopics(topics, data, started_at) ->
      execute_binary_topics(state, socket_id, topics, data, started_at)
    StepCloseTopic(topic_name, reason, continuation) ->
      execute_close_topic(state, socket_id, topic_name, reason, continuation)
    StepCloseCleanup(
      topic_name,
      close_join_ref,
      reason,
      kicks,
      stop,
      continuation,
    ) ->
      execute_close_cleanup(
        state,
        socket_id,
        topic_name,
        CloseOutcome(
          close_join_ref: close_join_ref,
          reason: reason,
          kicks: kicks,
          stop: stop,
          continuation: continuation,
        ),
      )
    StepCloseFinish(
      topic_name,
      close_join_ref,
      reason,
      kicks,
      stop,
      continuation,
    ) -> {
      send_terminal_frame(state, socket_id, topic_name, close_join_ref, reason)
      Continue(state, continuation_steps(continuation, kicks, stop))
    }
    StepDrive(kicks, stop) -> execute_drive(state, socket_id, kicks, stop)
    StepTeardown(reason) -> execute_teardown(state, socket_id, reason)
    StepTeardownTopics(topics, reason) ->
      case topics {
        [] -> Continue(state, [])
        [topic_name, ..rest] ->
          Continue(state, [
            StepCloseTopic(
              topic_name,
              reason,
              ContinueTeardownTopics(rest, reason),
            ),
          ])
      }
    StepTeardownFinish(reason, connected_at, joined_channels) ->
      execute_teardown_finish(
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
    StepWorkerReport(topic_name, report) ->
      execute_worker_report(state, socket_id, topic_name, report)
  }
}

/// The tail of a topic close, bundled so `execute_close_cleanup` does not
/// need six positional parameters.
type CloseOutcome {
  CloseOutcome(
    close_join_ref: Option(String),
    reason: StopReason,
    kicks: List(String),
    stop: Option(StopReason),
    continuation: Continuation,
  )
}

/// The steps that hand an effect list's (or topic close's) kicks and stop
/// to whatever was waiting for them.
fn continuation_steps(
  continuation: Continuation,
  kicks: List(String),
  stop: Option(StopReason),
) -> List(Step(message)) {
  case continuation {
    ContinueDriving -> [StepDrive(kicks, stop)]
    ContinueKicks(rest) -> [StepDrive(list.append(rest, kicks), stop)]
    ContinueClosingTopic(topic_name, close_join_ref, reason, outer) -> [
      StepCloseCleanup(topic_name, close_join_ref, reason, kicks, stop, outer),
    ]
    // A teardown is already closing this socket's topics in order; a
    // `Closed` handler cannot kick or stop its way out of it.
    ContinueTeardownTopics(topics, reason) -> [
      StepTeardownTopics(topics, reason),
    ]
    ContinueFinishingUpdate(source, effects, outer) -> [
      StepFinishUpdate(source, effects),
      ..continuation_steps(outer, kicks, stop)
    ]
  }
}

fn effects_callback_result(effects: List(Effect)) -> telemetry.CallbackResult {
  case effects {
    [] -> telemetry.NoReply
    [effect, ..rest] ->
      case effect {
        socket.ReplyOk(_, _) -> telemetry.Reply
        socket.ReplyError(_, _) -> telemetry.ReplyError
        socket.Push(_, _, _)
        | socket.Broadcast(_, _, _)
        | socket.BroadcastFrom(_, _, _) -> telemetry.Push
        socket.AcceptJoin(..)
        | socket.RejectJoin(..)
        | socket.PresenceTrack(..)
        | socket.PresenceUntrack(..)
        | socket.PushPresence(..)
        | socket.BroadcastPresence(..)
        | socket.KickTopic(..) -> effects_callback_result(rest)
      }
  }
}

fn emit_missing_socket_telemetry(
  state: State(model, message),
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
  state: State(model, message),
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
  state: State(model, message),
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
/// its effect list. Kick and stop follow-ups reach `continuation` only once
/// every effect has been applied — they are never applied mid-list.
fn execute_input(
  state: State(model, message),
  socket_id: String,
  input: Input(message),
  source: Source,
  continuation: Continuation,
) -> Execution(model, message) {
  case dict.get(state.sockets, socket_id), state.role {
    Error(Nil), SocketActorRole(..) | Error(Nil), RouterRole(..) -> {
      emit_missing_socket_telemetry(state, source)
      Continue(state, continuation_steps(continuation, [], None))
    }
    // One process per topic: a join starts that topic's worker and a
    // message is cast to it. `Binary` and `Info` are socket-scoped and
    // still reach `update`; `Closed` for a worker topic never gets
    // here, because `execute_close_topic` routes the close to the worker.
    Ok(socket), SocketActorRole(workers: Some(workers), ..) ->
      case input {
        socket.Join(topic: topic_name, payload:, ref:) ->
          execute_worker_join(
            state,
            socket_id,
            socket,
            workers,
            topic_name,
            payload,
            ref,
            source,
            continuation,
          )
        socket.Message(topic: topic_name, event:, payload:, ref:) -> {
          case dict.get(socket.workers, topic_name) {
            Ok(worker) ->
              process.send(
                worker.subject,
                WorkerDeliver(event, payload, ref, source),
              )
            Error(Nil) ->
              state.logger
              |> log.warn("Message dropped: topic has no worker", [
                #("socket_id", socket_id),
                #("topic", topic_name),
              ])
          }
          Continue(state, continuation_steps(continuation, [], None))
        }
        socket.Binary(..) | socket.Info(..) | socket.Closed(..) ->
          execute_socket_update(
            state,
            socket_id,
            socket,
            input,
            source,
            continuation,
          )
      }
    Ok(socket), SocketActorRole(workers: None, ..)
    | Ok(socket), RouterRole(..)
    ->
      execute_socket_update(
        state,
        socket_id,
        socket,
        input,
        source,
        continuation,
      )
  }
}

fn execute_socket_update(
  state: State(model, message),
  socket_id: String,
  socket_state: SocketState(model, message),
  input: Input(message),
  source: Source,
  continuation: Continuation,
) -> Execution(model, message) {
  let update = state.update
  let model = socket_state.model
  // Crash boundary: see `internal.rescue`. The error path discards the
  // callback result and closes the narrowest safe scope.
  execute_update_result(
    state,
    socket_id,
    source,
    continuation,
    internal.rescue(fn() { update(model, input) }),
  )
}

fn execute_update_result(
  state: State(model, message),
  socket_id: String,
  source: Source,
  continuation: Continuation,
  result: Result(Next(model), String),
) -> Execution(model, message) {
  case result {
    Error(crash) ->
      execute_update_crash(state, socket_id, source, continuation, crash)
    Ok(socket.Stop(reason)) -> {
      state.logger
      |> log.debug("Update stopped socket", [
        #("socket_id", socket_id),
        #("reason", stop_reason_to_string(reason)),
      ])
      // A join answered with Stop is still unanswered on the wire: fail it
      // closed before the teardown frames.
      reject_stopped_join(state, socket_id, source)
      emit_stopped_update_telemetry(state, source)
      Continue(state, continuation_steps(continuation, [], Some(reason)))
    }
    Ok(socket.Next(new_model, effects)) -> {
      let pending = case source {
        JoinSource(topic_name, join_ref, message_ref, ref, _) ->
          Some(Pending(topic_name, join_ref, message_ref, ref))
        MessageSource(..) | InfoSource(..) | ClosedSource -> None
      }
      Continue(store_model(state, socket_id, new_model), [
        StepEffects(
          effects,
          pending,
          [],
          ContinueFinishingUpdate(source, effects, continuation),
        ),
      ])
    }
  }
}

/// Crash policy: joins are rejected and the socket survives; topic-scoped
/// events close just that topic; `Info` (no topic to attribute) tears down
/// the socket; a crash while handling `Closed` is logged and teardown
/// continues with the last good model.
fn execute_update_crash(
  state: State(model, message),
  socket_id: String,
  source: Source,
  continuation: Continuation,
  crash: String,
) -> Execution(model, message) {
  case source {
    JoinSource(topic_name, join_ref, message_ref, _, started_at) -> {
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
        message_ref,
        error_reason("join crashed"),
      )
      emit_join_stop(state, started_at, telemetry.JoinCallbackFailed)
      Continue(state, continuation_steps(continuation, [], None))
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
      Continue(state, [
        StepCloseTopic(topic_name, socket.Errored(crash), continuation),
      ])
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
        StepTeardown(socket.Errored(crash)),
        ..continuation_steps(continuation, [], None)
      ])
    }
    ClosedSource -> {
      state.logger
      |> log.error("Update crashed handling closed", [
        #("socket_id", socket_id),
        #("crash", crash),
      ])
      Continue(state, continuation_steps(continuation, [], None))
    }
  }
}

/// Fail closed when an update returns `Stop` while handling a join.
fn reject_stopped_join(
  state: State(model, message),
  socket_id: String,
  source: Source,
) -> Nil {
  case source {
    JoinSource(topic_name, join_ref, message_ref, ref, _) ->
      reject_unanswered_join(
        state,
        socket_id,
        Pending(topic_name, join_ref, message_ref, ref),
      )
    MessageSource(..) | InfoSource(..) | ClosedSource -> Nil
  }
}

/// Fail-closed reply for a join the update never answered.
fn reject_unanswered_join(
  state: State(model, message),
  socket_id: String,
  pending: Pending,
) -> Nil {
  send_error_reply(
    state,
    socket_id,
    pending.topic,
    pending.join_ref,
    pending.message_ref,
    error_reason("join not acknowledged"),
  )
}

/// Deliver a join once whatever had to happen first (the close of a
/// duplicate instance, including its presence cleanup) has finished.
fn execute_deliver_join(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> Execution(model, message) {
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
    #("ref", option_to_log_string(ref)),
    #("join_ref", option_to_log_string(join_ref)),
  ])
  let pending_ref =
    socket.make_join_ref(
      topic: topic_name,
      join_ref: join_ref,
      message_ref: ref,
    )
  Continue(state, [
    StepInput(
      socket.Join(topic: topic_name, payload: payload, ref: pending_ref),
      JoinSource(topic_name, join_ref, ref, pending_ref, started_at),
      ContinueDriving,
    ),
  ])
}

/// Hand an undecodable binary frame to the next joined topic. Subscription
/// is re-checked per topic because an earlier delivery may have closed it.
fn execute_binary_topics(
  state: State(model, message),
  socket_id: String,
  topics: List(String),
  data: BitArray,
  started_at: Int,
) -> Execution(model, message) {
  case topics {
    [] -> Continue(state, [])
    [topic_name, ..rest] ->
      case socket_subscribed(state, socket_id, topic_name) {
        False -> Continue(state, [StepBinaryTopics(rest, data, started_at)])
        True ->
          Continue(state, [
            StepInput(
              socket.Binary(topic: topic_name, data: data),
              MessageSource(topic_name, telemetry.BinaryMessage, started_at),
              ContinueDriving,
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
fn execute_drive(
  state: State(model, message),
  socket_id: String,
  kicks: List(String),
  stop: Option(StopReason),
) -> Execution(model, message) {
  case stop, kicks {
    Some(reason), _ -> Continue(state, [StepTeardown(reason)])
    None, [] -> Continue(state, [])
    None, [topic_name, ..rest] ->
      case socket_subscribed(state, socket_id, topic_name) {
        // A topic that is no longer joined drops out of the queue.
        False -> Continue(state, [StepDrive(rest, None)])
        True ->
          Continue(state, [
            StepCloseTopic(topic_name, socket.Shutdown, ContinueKicks(rest)),
          ])
      }
  }
}

/// Close one topic subscription: remove the subscription state, then
/// deliver `Closed` to the app. Subscription state is removed *before* the
/// `Closed` delivery, so pushes to the closing topic drop while broadcasts
/// still reach the topic's remaining subscribers. The auto-untrack and the
/// terminal frame follow in `StepCloseCleanup`/`StepCloseFinish`.
fn execute_close_topic(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  reason: StopReason,
  continuation: Continuation,
) -> Execution(model, message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Continue(state, continuation_steps(continuation, [], None))
    Ok(socket) ->
      case dict.has_key(socket.join_refs, topic_name) {
        False -> Continue(state, continuation_steps(continuation, [], None))
        True -> {
          state.logger
          |> log.debug("Topic closed", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("reason", stop_reason_to_string(reason)),
          ])
          let close_join_ref = joined_ref(socket, topic_name)
          let worker = dict.get(socket.workers, topic_name)
          // `join_refs` ends the join now, so a second close is a no-op,
          // and the router index entry removed below stops broadcasts. A
          // raw topic also leaves the joined set and drops its outstanding
          // reply refs here, before `Closed` runs. A worker topic keeps both
          // until the worker stops. Results that it computed before the close
          // can still push to and answer the topic. All other socket work
          // waits until the close completes. `execute_close_cleanup` drops the
          // refs after the runtime applies those results.
          let socket =
            SocketState(
              ..socket,
              join_refs: dict.delete(socket.join_refs, topic_name),
              workers: dict.delete(socket.workers, topic_name),
            )
          let state = store_socket(state, socket)
          let state = case worker {
            Ok(_) -> state
            Error(Nil) -> unsubscribe_topic(state, socket_id, topic_name)
          }
          let state = remove_channel_bucket(state, socket_id, topic_name)
          let state = remove_topic_subscriber(state, socket_id, topic_name)
          case worker {
            Ok(worker) ->
              close_worker_topic(
                state,
                socket_id,
                topic_name,
                worker,
                close_join_ref,
                reason,
                continuation,
              )
            Error(Nil) ->
              Continue(state, [
                StepInput(
                  socket.Closed(topic: topic_name, reason: reason),
                  ClosedSource,
                  ContinueClosingTopic(
                    topic_name,
                    close_join_ref,
                    reason,
                    continuation,
                  ),
                ),
              ])
          }
        }
      }
  }
}

/// Remove a socket from a topic's subscriber set, unsubscribing from
/// PubSub and dropping the topic entry when it was the last subscriber.
fn remove_topic_subscriber(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
) -> State(model, message) {
  let subscribers =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
    |> set.delete(socket_id)
  case state.role {
    SocketActorRole(router:, ..) ->
      process.send(router, IndexLeave(socket_id, topic_name))
    RouterRole(..) -> Nil
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
/// In a socket actor the set only ever holds that one socket, and the
/// router is told so it can keep the global index and the pg
/// subscription. That notification is a cast, not a call — neither side
/// may ever block on the other. It is sent from `subscribe_socket`, before the join
/// reply frame leaves this turn, so a client that acts on its own reply
/// cannot beat its index entry to the router. A broadcast from a third
/// process that races the cast still misses the socket: that is decision
/// 2's cast option and its documented window.
fn add_topic_subscriber(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
) -> State(model, message) {
  let existing =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
  case state.role {
    SocketActorRole(router:, ..) ->
      process.send(router, IndexJoin(socket_id, topic_name))
    RouterRole(..) ->
      case state.subscriber, set.is_empty(existing) {
        Some(subscriber), True -> pubsub.join(subscriber, topic_name)
        Some(_), False | None, True | None, False -> Nil
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
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  close_join_ref: Option(String),
  reason: StopReason,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) -> {
      let encoder = case reason {
        socket.Errored(_) -> codec.encode_error(socket.codec)
        socket.Normal | socket.Shutdown | socket.HeartbeatTimeout ->
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
/// by `execute_close_topic`'s own joined check. No topic can be joined during
/// teardown, so the list taken up front covers every close.
fn execute_teardown(
  state: State(model, message),
  socket_id: String,
  reason: StopReason,
) -> Execution(model, message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Continue(state, [])
    Ok(socket) -> {
      state.logger
      |> log.debug(
        "Socket teardown",
        list.append(
          [
            #("socket_id", socket_id),
            #("reason", stop_reason_to_string(reason)),
          ],
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

fn execute_teardown_finish(
  state: State(model, message),
  socket_id: String,
  reason: StopReason,
  connected_at: Int,
  joined_channels: Int,
) -> Execution(model, message) {
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
      reason: stop_reason_to_disconnect_reason(reason),
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
  state: State(model, message),
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
/// closed) and the collected kicks are handed to `continuation`.
fn run_effects(
  state: State(model, message),
  socket_id: String,
  effects: List(Effect),
  pending: Option(Pending),
  kicks: List(String),
  continuation: Continuation,
) -> Execution(model, message) {
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
      Continue(state, continuation_steps(continuation, kicks, None))
    }
    [socket.PresenceTrack(topic_name, key, meta), ..rest] ->
      start_presence_track(state, socket_id, topic_name, key, meta, [
        StepEffects(rest, pending, kicks, continuation),
      ])
    [socket.PresenceUntrack(topic_name, key), ..rest] ->
      start_presence_untrack(state, socket_id, topic_name, key, [
        StepEffects(rest, pending, kicks, continuation),
      ])
    [effect, ..rest] -> {
      let #(state, pending, kicks) =
        apply_effect(state, socket_id, effect, pending, kicks)
      run_effects(state, socket_id, rest, pending, kicks, continuation)
    }
  }
}

/// Apply one synchronous effect, returning the accumulator the fold used
/// to thread: the next state, the still-unanswered pending join, and the
/// kicked topics collected so far.
fn apply_effect(
  state: State(model, message),
  socket_id: String,
  effect: Effect,
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, message), Option(Pending), List(String)) {
  case effect {
    socket.AcceptJoin(ref, reply) ->
      apply_accept_join(state, socket_id, ref, reply, pending, kicks)
    socket.RejectJoin(ref, reason) ->
      apply_reject_join(state, socket_id, ref, reason, pending, kicks)
    socket.ReplyOk(ref, payload) -> {
      let state = apply_reply(state, socket_id, ref, codec.StatusOk, payload)
      #(state, pending, kicks)
    }
    socket.ReplyError(ref, payload) -> {
      let state = apply_reply(state, socket_id, ref, codec.StatusError, payload)
      #(state, pending, kicks)
    }
    socket.Push(topic_name, event_name, payload) -> {
      apply_push(state, socket_id, topic_name, event_name, payload)
      #(state, pending, kicks)
    }
    socket.Broadcast(topic_name, event_name, payload) -> {
      broadcast_with_pubsub(state, topic_name, event_name, payload, None)
      #(state, pending, kicks)
    }
    socket.BroadcastFrom(topic_name, event_name, payload) -> {
      broadcast_with_pubsub(
        state,
        topic_name,
        event_name,
        payload,
        Some(socket_id),
      )
      #(state, pending, kicks)
    }
    socket.PushPresence(topic_name, event_name, encode) -> {
      case presence_snapshot(state, socket_id, topic_name, encode) {
        Ok(payload) ->
          apply_push(state, socket_id, topic_name, event_name, payload)
        Error(Nil) -> Nil
      }
      #(state, pending, kicks)
    }
    socket.BroadcastPresence(topic_name, event_name, encode) -> {
      case presence_snapshot(state, socket_id, topic_name, encode) {
        Ok(payload) ->
          broadcast_with_pubsub(state, topic_name, event_name, payload, None)
        Error(Nil) -> Nil
      }
      #(state, pending, kicks)
    }
    socket.KickTopic(topic_name) ->
      apply_kick_topic(state, socket_id, topic_name, pending, kicks)
    // Handled by `run_effects`, which parks the socket on them.
    socket.PresenceTrack(_, _, _) | socket.PresenceUntrack(_, _) -> #(
      state,
      pending,
      kicks,
    )
  }
}

fn apply_kick_topic(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, message), Option(Pending), List(String)) {
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
  state: State(model, message),
  socket_id: String,
  ref: JoinRef,
  reply: Option(Json),
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, message), Option(Pending), List(String)) {
  case matching_pending_join(ref, pending) {
    Some(pending_join) -> {
      let state = subscribe_socket(state, socket_id, pending_join)
      release_worker(state, socket_id, pending_join.topic)
      case dict.get(state.sockets, socket_id) {
        Ok(socket) -> {
          let response = option.unwrap(reply, json.object([]))
          let frame =
            codec.encode_reply(socket.codec)(
              pending_join.join_ref,
              pending_join.message_ref,
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
  state: State(model, message),
  socket_id: String,
  ref: JoinRef,
  reason: Json,
  pending: Option(Pending),
  kicks: List(String),
) -> #(State(model, message), Option(Pending), List(String)) {
  case matching_pending_join(ref, pending) {
    Some(pending_join) -> {
      state.logger
      |> log.debug("Join rejected", [
        #("socket_id", socket_id),
        #("topic", pending_join.topic),
      ])
      send_error_reply(
        state,
        socket_id,
        pending_join.topic,
        pending_join.join_ref,
        pending_join.message_ref,
        reason,
      )
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
    Some(pending_join) ->
      case socket.join_refs_match(ref, pending_join.ref) {
        True -> Some(pending_join)
        False -> None
      }
    None -> None
  }
}

fn warn_unmatched_join_answer(
  state: State(model, message),
  socket_id: String,
  ref: JoinRef,
  effect_name: String,
) -> Nil {
  state.logger
  |> log.warn(effect_name <> " ignored: no matching pending join", [
    #("socket_id", socket_id),
    #("topic", socket.join_ref_topic(ref)),
  ])
}

/// Commit an accepted join: record the subscription and join_ref, add the
/// socket to the topic's subscriber set, and subscribe the runtime to
/// PubSub when it is the topic's first local subscriber.
fn subscribe_socket(
  state: State(model, message),
  socket_id: String,
  pending_join: Pending,
) -> State(model, message) {
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
  state: State(model, message),
  socket_id: String,
  ref: ReplyRef,
  status: codec.ReplyStatus,
  payload: Json,
) -> State(model, message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) ->
      case set.contains(socket.pending_reply_refs, ref) {
        False -> {
          state.logger
          |> log.warn("Reply ignored: unknown or already-answered ref", [
            #("socket_id", socket_id),
            #("topic", socket.reply_ref_topic(ref)),
          ])
          state
        }
        True -> {
          let frame =
            codec.encode_reply(socket.codec)(
              socket.reply_ref_join_ref(ref),
              socket.reply_ref_message_ref(ref),
              socket.reply_ref_topic(ref),
              status,
              payload,
            )
          let _send_result =
            send_frame_logged(state, socket, socket.reply_ref_topic(ref), frame)
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

/// Take a topic out of the joined set and drop its outstanding reply refs:
/// pushes to it drop from here on, and a ref stored across a leave/rejoin
/// is not replied to.
fn unsubscribe_topic(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
) -> State(model, message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) ->
      store_socket(
        state,
        SocketState(
          ..socket,
          subscribed_topics: set.delete(socket.subscribed_topics, topic_name),
          pending_reply_refs: set.filter(socket.pending_reply_refs, fn(ref) {
            socket.reply_ref_topic(ref) != topic_name
          }),
        ),
      )
  }
}

/// Record a message reply ref as outstanding for a socket.
fn register_reply_ref(
  state: State(model, message),
  socket_id: String,
  ref: ReplyRef,
) -> State(model, message) {
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
  state: State(model, message),
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
/// `finish_presence_operation` tell an intentional, expected non-wait
/// (`Stopping`)
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
fn begin_presence_operation(
  state: State(model, message),
  socket_id: String,
  handle: presence.Presence,
  operation: PresenceOperation,
  send: fn(Int, Subject(presence.MutationAck)) -> Nil,
  resume: List(Step(message)),
) -> Execution(model, message) {
  case presence.is_running(handle), state.stopping {
    False, True | False, False -> {
      state.logger
      |> log.error("Presence mutation skipped: presence actor not running", [
        #("socket_id", socket_id),
        #("topic", presence_operation_topic(operation)),
      ])
      Continue(
        finish_presence_operation(
          state,
          socket_id,
          operation,
          Error(PresenceNotRunning),
        ),
        resume,
      )
    }
    True, True -> {
      // Shutting down: fire and forget. A track cannot be completed at all
      // (its ref would be lost with the runtime), so it is dropped; the
      // untracks still need to reach presence.
      case operation {
        TrackOperation(_, _, _) ->
          state.logger
          |> log.warn("PresenceTrack dropped: runtime stopping", [
            #("socket_id", socket_id),
            #("topic", presence_operation_topic(operation)),
          ])
        UntrackOperation(_, _, _) -> send(0, state.presence_acknowledgement)
      }
      Continue(
        finish_presence_operation(
          state,
          socket_id,
          operation,
          Error(PresenceStopping),
        ),
        resume,
      )
    }
    True, False -> {
      let operation_id = state.next_operation_id
      send(operation_id, state.presence_acknowledgement)
      let timer =
        process.send_after(
          state.self_subject,
          state.config.presence_op_timeout_ms,
          PresenceOperationTimedOut(socket_id, operation_id),
        )
      Await(
        State(..state, next_operation_id: operation_id + 1),
        PresenceWait(operation_id, operation),
        timer,
        resume,
      )
    }
  }
}

fn presence_operation_topic(operation: PresenceOperation) -> String {
  case operation {
    TrackOperation(topic_name, _, _) -> topic_name
    UntrackOperation(topic_name, _, _) -> topic_name
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
fn finish_presence_operation(
  state: State(model, message),
  socket_id: String,
  operation: PresenceOperation,
  outcome: Result(presence.MutationOutcome, PresenceGiveUp),
) -> State(model, message) {
  case operation, outcome {
    TrackOperation(topic_name, key, replaced), Ok(presence.Tracked(ref, meta))
    -> {
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
    TrackOperation(topic_name, _key, replaced), Error(PresenceStopping) -> {
      // Already logged (as a warning) where shutdown decided not to wait;
      // nothing more to log here.
      case replaced {
        [] -> Nil
        _ -> broadcast_presence_diff(state, topic_name, [], replaced)
      }
      state
    }
    TrackOperation(topic_name, key, replaced), Error(PresenceTimedOut) -> {
      let state = failed_track(state, socket_id, topic_name, key, replaced)
      // The mutation did reach the presence actor and may still be
      // applied: remember that an acknowledgement — and with it a ref only
      // the compensation will ever learn — is still owed for this socket.
      note_unacknowledged_track(state, socket_id)
    }
    // `PresenceNotRunning` never reached the actor, and an `Untracked`
    // acknowledgement for a track is a protocol impossibility (an
    // acknowledgement only ever reaches the operation it was minted for).
    // Neither can leave an entry behind, so neither is owed compensation.
    TrackOperation(topic_name, key, replaced), Error(PresenceNotRunning)
    | TrackOperation(topic_name, key, replaced), Ok(presence.Untracked)
    -> failed_track(state, socket_id, topic_name, key, replaced)
    UntrackOperation(topic_name, leaves, _), Ok(_) -> {
      broadcast_presence_diff(state, topic_name, [], leaves)
      state
    }
    UntrackOperation(topic_name, leaves, automatic), Error(PresenceStopping) -> {
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
    UntrackOperation(topic_name, leaves, automatic), Error(PresenceNotRunning)
    | UntrackOperation(topic_name, leaves, automatic), Error(PresenceTimedOut)
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
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  key: String,
  replaced: List(presence.PresenceEntry),
) -> State(model, message) {
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
fn note_unacknowledged_track(
  state: State(model, message),
  socket_id: String,
) -> State(model, message) {
  let outstanding =
    dict.get(state.unacknowledged_tracks, socket_id)
    |> result.unwrap(0)
  State(
    ..state,
    unacknowledged_tracks: dict.insert(
      state.unacknowledged_tracks,
      socket_id,
      outstanding + 1,
    ),
  )
}

/// One of a socket's outstanding acknowledgements has now arrived (and been
/// compensated), so it no longer needs sweeping at shutdown.
fn clear_unacknowledged_track(
  state: State(model, message),
  socket_id: String,
) -> State(model, message) {
  case dict.get(state.unacknowledged_tracks, socket_id) {
    Error(Nil) | Ok(1) ->
      State(
        ..state,
        unacknowledged_tracks: dict.delete(
          state.unacknowledged_tracks,
          socket_id,
        ),
      )
    Ok(outstanding) ->
      State(
        ..state,
        unacknowledged_tracks: dict.insert(
          state.unacknowledged_tracks,
          socket_id,
          outstanding - 1,
        ),
      )
  }
}

fn store_presence_ref(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  key: String,
  ref: String,
  meta: Json,
) -> State(model, message) {
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
fn handle_presence_acknowledgement(
  state: State(model, message),
  acknowledgement: presence.MutationAck,
) -> State(model, message) {
  case dict.get(state.suspended, acknowledgement.tag) {
    Error(Nil) -> {
      state.logger
      |> log.debug("Presence acknowledgement ignored: no socket waiting", [
        #("socket_id", acknowledgement.tag),
        #("op_id", int.to_string(acknowledgement.operation_id)),
      ])
      compensate_stale_acknowledgement(state, acknowledgement)
    }
    Ok(suspension) ->
      case suspension.waiting {
        PresenceWait(operation_id:, operation:)
          if operation_id == acknowledgement.operation_id
        -> {
          let _cancelled = process.cancel_timer(suspension.timer)
          resume_socket(
            state,
            acknowledgement.tag,
            operation,
            suspension.stack,
            Ok(acknowledgement.outcome),
          )
        }
        PresenceWait(..) | WorkerWait(..) -> {
          state.logger
          |> log.debug("Presence acknowledgement ignored: stale operation", [
            #("socket_id", acknowledgement.tag),
            #("op_id", int.to_string(acknowledgement.operation_id)),
          ])
          compensate_stale_acknowledgement(state, acknowledgement)
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
/// reaches a live suspension: the operation id it is sent under is freshly
/// drawn
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
fn compensate_stale_acknowledgement(
  state: State(model, message),
  acknowledgement: presence.MutationAck,
) -> State(model, message) {
  case acknowledgement.outcome {
    presence.Untracked -> state
    // The acknowledgement this socket was still owed has now arrived, so
    // shutdown no longer has to sweep its session — whether or not a
    // presence actor is still around to act on the ref it carries.
    presence.Tracked(ref, _meta) ->
      untrack_stale_ref(
        clear_unacknowledged_track(state, acknowledgement.tag),
        acknowledgement.tag,
        ref,
      )
  }
}

/// Ask presence to remove exactly the ref a stale acknowledgement carried.
fn untrack_stale_ref(
  state: State(model, message),
  socket_id: String,
  ref: String,
) -> State(model, message) {
  case state.config.presence {
    None -> state
    Some(handle) ->
      case presence.is_running(handle) {
        False -> state
        True -> {
          let operation_id = state.next_operation_id
          presence.untrack_async(
            presence: handle,
            refs: [ref],
            tag: socket_id,
            operation_id: operation_id,
            reply: state.presence_acknowledgement,
          )
          state.logger
          |> log.debug(
            "Presence acknowledgement compensated: untracking stale entry",
            [#("socket_id", socket_id), #("ref", ref)],
          )
          State(..state, next_operation_id: operation_id + 1)
        }
      }
  }
}

fn handle_presence_timeout(
  state: State(model, message),
  socket_id: String,
  operation_id: Int,
) -> State(model, message) {
  case dict.get(state.suspended, socket_id) {
    Error(Nil) -> state
    Ok(suspension) ->
      case suspension.waiting {
        PresenceWait(operation_id: awaiting, operation:)
          if awaiting == operation_id
        -> {
          state.logger
          |> log.error("Presence mutation timed out", [
            #("socket_id", socket_id),
            #("topic", presence_operation_topic(operation)),
            #("op_id", int.to_string(operation_id)),
            #("timeout_ms", int.to_string(state.config.presence_op_timeout_ms)),
          ])
          resume_socket(
            state,
            socket_id,
            operation,
            suspension.stack,
            Error(PresenceTimedOut),
          )
        }
        PresenceWait(..) | WorkerWait(..) -> state
      }
  }
}

fn resume_socket(
  state: State(model, message),
  socket_id: String,
  operation: PresenceOperation,
  stack: List(Step(message)),
  outcome: Result(presence.MutationOutcome, PresenceGiveUp),
) -> State(model, message) {
  let state = State(..state, suspended: dict.delete(state.suspended, socket_id))
  let state = finish_presence_operation(state, socket_id, operation, outcome)
  // `run` may park the socket again on a later presence effect or a
  // closing topic's worker; the drain then stops and leaves the rest of
  // the queue for the next resume.
  drain_queue(run(state, socket_id, stack), socket_id)
}

/// Start a `PresenceTrack`. Tracking a key this socket already holds is an
/// atomic replacement: the previous ref goes to the presence actor with
/// the new entry, so the topic never materializes a snapshot without the
/// key, and the replacement is published as one leave plus one join.
fn start_presence_track(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  key: String,
  meta: Json,
  resume: List(Step(message)),
) -> Execution(model, message) {
  case state.config.presence, dict.get(state.sockets, socket_id) {
    None, Ok(_) | None, Error(Nil) -> {
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
      // `begin_presence_operation` drops a track fire-and-forget under this
      // exact
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
        Ok(_), True | Error(Nil), True -> state
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
      let operation =
        TrackOperation(
          topic: topic_name,
          key: key,
          replaced: case previous, dropping_for_stop {
            Ok(_), True | Error(Nil), True -> []
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
      begin_presence_operation(
        state,
        socket_id,
        handle,
        operation,
        fn(operation_id, reply) {
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
            operation_id: operation_id,
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
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  key: String,
  resume: List(Step(message)),
) -> Execution(model, message) {
  case state.config.presence, dict.get(state.sockets, socket_id) {
    None, Ok(_) -> {
      state.logger
      |> log.warn("PresenceUntrack dropped: no presence handle configured", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      Continue(state, resume)
    }
    None, Error(Nil) | Some(_), Error(Nil) -> Continue(state, resume)
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
  state: State(model, message),
  socket_id: String,
  handle: presence.Presence,
  topic_name: String,
  key: String,
  tracked: #(String, Json),
  resume: List(Step(message)),
) -> Execution(model, message) {
  let #(ref, meta) = tracked
  begin_presence_operation(
    state,
    socket_id,
    handle,
    UntrackOperation(
      topic: topic_name,
      leaves: [
        presence.PresenceEntry(session_id: socket_id, key: key, meta: meta),
      ],
      automatic: False,
    ),
    fn(operation_id, reply) {
      presence.untrack_async(
        presence: handle,
        refs: [ref],
        tag: socket_id,
        operation_id: operation_id,
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
fn execute_close_cleanup(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  close: CloseOutcome,
) -> Execution(model, message) {
  let resume = [
    StepCloseFinish(
      topic_name,
      close.close_join_ref,
      close.reason,
      close.kicks,
      close.stop,
      close.continuation,
    ),
  ]
  // The runtime has applied each result that can still push to or answer the
  // topic. This is a no-op for a raw topic because `execute_close_topic`
  // already
  // removed its subscription.
  let state = unsubscribe_topic(state, socket_id, topic_name)
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
    Some(_), Error(Nil) | None, Ok(_) | None, Error(Nil) ->
      Continue(state, resume)
  }
}

fn drop_topic_presence_refs(
  state: State(model, message),
  socket: SocketState(model, message),
  topic_name: String,
) -> State(model, message) {
  store_socket(
    state,
    SocketState(
      ..socket,
      presence_refs: dict.delete(socket.presence_refs, topic_name),
    ),
  )
}

fn begin_topic_cleanup(
  state: State(model, message),
  socket_id: String,
  handle: presence.Presence,
  topic_name: String,
  entries: List(#(String, #(String, Json))),
  resume: List(Step(message)),
) -> Execution(model, message) {
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
  begin_presence_operation(
    state,
    socket_id,
    handle,
    UntrackOperation(topic: topic_name, leaves: leaves, automatic: True),
    fn(operation_id, reply) {
      presence.untrack_async(
        presence: handle,
        refs: refs,
        tag: socket_id,
        operation_id: operation_id,
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
  state: State(model, message),
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
  state: State(model, message),
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
  state: State(model, message),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
) -> Int {
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
    #("except", option_to_log_string(except)),
  ])
  case state.role {
    // Socket actor: it is the only possible recipient, so encode and send
    // inline exactly as the shared runtime did. Send failures are logged
    // by `send_frame_logged` in this, the only process that sees them.
    SocketActorRole(..) ->
      list.fold(recipients, 0, fn(count, socket_id) {
        case dict.get(state.sockets, socket_id) {
          Ok(socket) -> {
            let frame =
              codec.encode_push(socket.codec)(topic_name, event_name, payload)
            let _send_result =
              send_frame_logged(state, socket, topic_name, frame)
            count + 1
          }
          Error(Nil) -> count
        }
      })
    // Decision 1: the router resolves recipients and hands each one to its
    // own actor, so encoding happens on N schedulers instead of in this
    // turn, and only one process ever writes to a given transport.
    RouterRole(socket_actors:, ..) -> {
      list.each(recipients, fn(socket_id) {
        case dict.get(socket_actors, socket_id) {
          Ok(ref) ->
            process.send(
              ref.subject,
              Broadcast(topic_name, event_name, payload, except),
            )
          Error(Nil) -> Nil
        }
      })
      list.length(recipients)
    }
  }
}

fn emit_broadcast(
  state: State(model, message),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
  origin: telemetry.BroadcastOrigin,
) -> Nil {
  let started_at = telemetry_start(state)
  let recipients =
    local_broadcast(state, topic_name, event_name, payload, except)
  use <- bool.guard(when: !state.config.telemetry, return: Nil)
  telemetry.emit(
    True,
    telemetry.BroadcastStop(
      duration: telemetry.duration_since(started_at),
      recipients: recipients,
      origin: origin,
    ),
  )
}

/// Local fan-out plus distributed forwarding when PubSub is configured.
/// Used by the effect interpreter, which runs inside the runtime actor —
/// the actor's own pid is the PubSub sender, so the runtime does not echo
/// the message back to itself.
fn broadcast_with_pubsub(
  state: State(model, message),
  topic_name: String,
  event_name: String,
  payload: Json,
  except: Option(String),
) -> Nil {
  // A socket actor owns neither the topic index nor the PubSub handle, so
  // everything it originates goes to the router, which fans out locally
  // (one hop per recipient) and forwards to other nodes.
  //
  // This socket's own copy is sent inline first, so a broadcast to a topic
  // it is joined to still lands in effect-list order instead of arriving a
  // round trip later, behind the frames that followed it. The only
  // `except` a socket actor ever originates is its own id (`BroadcastFrom`),
  // so the exclusion handed to the router is always this socket.
  case state.role {
    SocketActorRole(router:, ..) -> {
      case except, dict.keys(state.sockets) {
        None, [socket_id] -> {
          let _recipient_count =
            local_broadcast(state, topic_name, event_name, payload, None)
          process.send(
            router,
            Broadcast(topic_name, event_name, payload, Some(socket_id)),
          )
        }
        None, [] | None, [_, _, ..] | Some(_), _ ->
          process.send(
            router,
            Broadcast(topic_name, event_name, payload, except),
          )
      }
    }
    RouterRole(..) -> {
      emit_broadcast(
        state,
        topic_name,
        event_name,
        payload,
        except,
        telemetry.Local,
      )
      case state.pubsub {
        Some(pubsub_instance) ->
          case except {
            None ->
              pubsub.broadcast_from(
                pubsub_instance,
                process.self(),
                topic_name,
                event_name,
                payload,
              )
            Some(socket_id) ->
              pubsub.broadcast_from_socket(
                pubsub_instance,
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
  }
}

fn handle_remote_broadcast(
  state: State(model, message),
  pubsub_message: pubsub.Message(Json),
) -> State(model, message) {
  let except = case pubsub_message.from {
    pubsub.FromSocket(_, socket_id) -> Some(socket_id)
    pubsub.System | pubsub.FromPid(_) -> None
  }
  emit_broadcast(
    state,
    pubsub_message.topic,
    pubsub_message.event,
    pubsub_message.payload,
    except,
    telemetry.Remote,
  )
  state
}

// ── Rate limiting ───────────────────────────────────────────────────────────

fn check_message_rate(
  state: State(model, message),
  socket_id: String,
) -> #(State(model, message), Bool) {
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
  state: State(model, message),
  socket_id: String,
) -> #(State(model, message), Bool) {
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
  state: State(model, message),
  socket_id: String,
  topic_name: String,
) -> #(State(model, message), Bool) {
  case resolve_channel_limits(state.config, topic_name) {
    None -> #(state, True)
    Some(limits) -> take_channel_token(state, socket_id, topic_name, limits)
  }
}

fn take_channel_token(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  limits: RateLimitConfig,
) -> #(State(model, message), Bool) {
  let socket_buckets =
    dict.get(state.channel_buckets, socket_id)
    |> result.unwrap(dict.new())
  let capacity = state.config.channel_limiter_max_keys_per_socket
  let over_capacity = case dict.has_key(socket_buckets, topic_name) {
    True -> False
    False -> capacity > 0 && dict.size(socket_buckets) >= capacity
  }
  use <- bool.guard(when: over_capacity, return: #(state, False))
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
  state: State(model, message),
  socket_id: String,
  topic_name: String,
) -> State(model, message) {
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
  state: State(model, message),
  socket_id: String,
) -> State(model, message) {
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
  state: State(model, message),
  socket: SocketState(model, message),
) -> State(model, message) {
  State(..state, sockets: dict.insert(state.sockets, socket.id, socket))
}

fn store_model(
  state: State(model, message),
  socket_id: String,
  model: model,
) -> State(model, message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) -> store_socket(state, SocketState(..socket, model: model))
  }
}

/// Send a `phx_reply` error to a socket (join rejections, rate limits).
fn send_error_reply(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  join_ref: Option(String),
  message_ref: Option(String),
  reason: Json,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) -> {
      let frame =
        codec.encode_reply(socket.codec)(
          join_ref,
          message_ref,
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
  socket: SocketState(model, message),
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
  state: State(model, message),
  socket: SocketState(model, message),
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

fn stop_reason_to_string(reason: StopReason) -> String {
  case reason {
    socket.Normal -> "normal"
    socket.Shutdown -> "shutdown"
    socket.HeartbeatTimeout -> "heartbeat_timeout"
    socket.Errored(message) -> message
  }
}

fn option_to_log_string(value: Option(String)) -> String {
  value
  |> option.unwrap("")
  |> topic.sanitize_for_log
}

fn joined_topics_metadata(
  socket: SocketState(model, message),
) -> List(#(String, String)) {
  let topics = set.to_list(socket.subscribed_topics)
  [
    #("joined_topic_count", int.to_string(list.length(topics))),
    #("joined_topics", string.join(topics, ",")),
  ]
}

// ── Topic workers ───────────────────────────────────────────────────────────
//
// `beryl/channel` uses one process for each accepted topic. The socket actor
// owns the protocol state, heartbeats, rate limits, refs, subscriptions, and
// frame writes. One temporary worker owns the state and callbacks for each
// joined topic. A per-socket factory supervisor starts these workers. The
// supervisor does not restart a stopped worker because that worker held the
// join and authorization state. The client must rejoin.
//
// The worker runs `join` during initialization. The socket actor waits on
// `start_child`, as a Phoenix socket waits on `join/3`. The runtime needs the
// result before the join turn ends. The worker then waits until the socket
// actor indexes the join. This sequence prevents self-notifications from
// reaching subscribers before the subscription exists. After this point,
// messages and typed mail are asynchronous. The worker sends effects to the
// socket actor. The actor applies them in arrival order. This preserves order
// for one topic. beryl does not define an order across topics on one socket.
//
// The socket sends a close to the worker before it drops the topic's reply
// refs. The socket waits until the worker stops. The worker mailbox is FIFO,
// so the worker first reports results that it computed before the close. The
// socket applies these results before it completes the close. Thus, a client
// that sends a message and then leaves can still receive its reply.

/// Maximum time for a `join` callback before the runtime rejects the join.
///
/// The socket actor waits for this time for each join.
///
/// ponytail: This fixed value matches the Phoenix start timeout. Add it to
/// `Config` when a deployment needs a longer timeout.
const worker_join_timeout_ms = 5000

/// Maximum time for a worker to finish queued work and `on_terminate`.
///
/// After this timeout, the runtime kills the worker and completes the close
/// without its termination actions.
///
/// ponytail: This fixed value matches the Phoenix
/// `Channel.Server.close/2` default. Add it to `Config` with
/// `worker_join_timeout_ms`.
const worker_terminate_timeout_ms = 5000

/// The worker contract that `beryl.worker_child_spec` hands to the runtime.
///
/// The socket actor calls `accepts` with the topic name before it starts a
/// worker for a join. `Error(reason)` rejects the join with that reason and
/// spawns no process. `open` runs in the new worker process for an accepted
/// topic.
pub type WorkerOpener {
  WorkerOpener(
    accepts: fn(String) -> Result(Nil, Json),
    open: fn(WorkerContext) -> WorkerOutcome,
  )
}

/// One socket actor's topic-worker machinery: the contract's pre-check and
/// the factory that starts one worker per accepted join.
type TopicWorkers {
  TopicWorkers(
    accepts: fn(String) -> Result(Nil, Json),
    factory: factory_supervisor.Supervisor(WorkerSpawn, WorkerStarted),
  )
}

/// The factory supervisor's child argument: one join attempt.
type WorkerSpawn {
  WorkerSpawn(
    socket_id: String,
    seed: ConnectSeed,
    topic: String,
    payload: Dynamic,
  )
}

/// The result that `start_child` returns after the worker runs `join`.
///
/// The result contains the worker subject and the join response. The response
/// is a reply with accept-time effects, or a rejection. The callbacks and
/// channel state stay in the worker.
type WorkerStarted =
  #(Subject(WorkerMessage), Result(#(Option(Json), List(Effect)), Json))

/// Work cast to one topic worker.
type WorkerMessage {
  /// A client message for `on_message`.
  WorkerDeliver(
    event: String,
    payload: Dynamic,
    ref: Option(ReplyRef),
    source: Source,
  )
  /// One sealed server-side message for `on_info`.
  ///
  /// The `Sender` sends it to the process for its join. After the join ends,
  /// the VM drops mail to that stopped process.
  WorkerInfo(mail: Mail)
  /// Run `on_terminate`, report its effects, and then stop.
  ///
  /// Send the report to `reply` when it is present. Otherwise, send it to the
  /// socket actor.
  WorkerTerminate(reason: StopReason, reply: Option(Subject(WorkerReport)))
  /// Stop without running any callback (a refused join has no channel).
  WorkerHalt
  /// The socket actor indexed the join. Handle held work in order, and then
  /// handle the mailbox.
  WorkerGo
}

type WorkerState {
  /// The socket actor accepted but did not index the join yet.
  ///
  /// See `release_worker`. Hold new work in newest-first order.
  WorkerHolding(worker: Worker, link: WorkerLink, held: List(WorkerMessage))
  WorkerRunning(worker: Worker, link: WorkerLink)
  /// A callback requested a topic close or panicked.
  ///
  /// Accept only the termination request in this state. Drop messages for the
  /// closing channel. Run `on_terminate` with the state from before the panic,
  /// or with the state returned by the callback that requested the close.
  WorkerClosing(worker: Worker, link: WorkerLink)
  WorkerRefusing
}

/// A worker's line back to its socket actor.
type WorkerLink {
  WorkerLink(
    topic: String,
    /// Send one report to the owning socket actor, tagged with this
    /// worker's pid.
    report: fn(WorkerReport) -> Nil,
    telemetry: Bool,
  )
}

/// Start one topic worker and run `join` in the new process.
///
/// The supervisor child template contains `open`, the socket actor subject,
/// and the telemetry flag. `spawn` contains data for one join. If `join`
/// panics, the worker start returns a bounded error description. The socket
/// actor converts that error to a rejection.
fn start_worker(
  open: fn(WorkerContext) -> WorkerOutcome,
  socket: Subject(Message(message)),
  telemetry: Bool,
  spawn: WorkerSpawn,
) -> actor.StartResult(WorkerStarted) {
  actor.new_with_initialiser(worker_join_timeout_ms, fn(subject) {
    let context =
      socket.WorkerContext(
        socket_id: spawn.socket_id,
        seed: spawn.seed,
        topic: spawn.topic,
        payload: spawn.payload,
        deliver: fn(mail) { process.send(subject, WorkerInfo(mail)) },
      )
    // Crash boundary: see `internal.rescue`.
    use outcome <- result.try(internal.rescue(fn() { open(context) }))
    let self = process.self()
    let link =
      WorkerLink(
        topic: spawn.topic,
        report: fn(report) {
          process.send(
            socket,
            WorkerReport(spawn.socket_id, spawn.topic, self, report),
          )
        },
        telemetry:,
      )
    let #(state, answer) = case outcome {
      socket.WorkerRejected(reason) -> {
        process.send(subject, WorkerHalt)
        #(WorkerRefusing, Error(reason))
      }
      socket.WorkerAccepted(reply:, effects:, worker:) -> #(
        WorkerHolding(worker, link, []),
        Ok(#(reply, effects)),
      )
    }
    actor.initialised(state)
    |> actor.returning(#(subject, answer))
    |> Ok
  })
  |> actor.on_message(handle_worker_msg)
  |> actor.start
}

fn handle_worker_msg(
  state: WorkerState,
  message: WorkerMessage,
) -> actor.Next(WorkerState, WorkerMessage) {
  case serve(state, message) {
    Ok(state) -> actor.continue(state)
    Error(Nil) -> actor.stop()
  }
}

/// Serve one message; `Error(Nil)` once the worker has stopped.
fn serve(
  state: WorkerState,
  message: WorkerMessage,
) -> Result(WorkerState, Nil) {
  case state {
    WorkerRefusing -> Error(Nil)
    WorkerHolding(worker, link, held) ->
      case message {
        WorkerHalt -> Error(Nil)
        WorkerGo ->
          list.try_fold(list.reverse(held), WorkerRunning(worker, link), serve)
        WorkerDeliver(..) | WorkerInfo(..) | WorkerTerminate(..) ->
          Ok(WorkerHolding(worker, link, [message, ..held]))
      }
    WorkerRunning(worker, link) ->
      case message {
        WorkerHalt -> Error(Nil)
        WorkerGo -> Ok(state)
        WorkerDeliver(event, payload, ref, source) ->
          Ok(
            worker_step(worker, link, source, fn() {
              worker.on_message(event, payload, ref)
            }),
          )
        WorkerInfo(mail) -> {
          let source =
            MessageSource(
              link.topic,
              telemetry.InfoMessage,
              start_time_if(link.telemetry),
            )
          Ok(worker_step(worker, link, source, fn() { worker.on_info(mail) }))
        }
        WorkerTerminate(reason, reply) ->
          terminate_worker(worker, link, reason, reply)
      }
    WorkerClosing(worker, link) ->
      case message {
        WorkerHalt -> Error(Nil)
        WorkerGo | WorkerDeliver(..) | WorkerInfo(..) -> Ok(state)
        WorkerTerminate(reason, reply) ->
          terminate_worker(worker, link, reason, reply)
      }
  }
}

fn terminate_worker(
  worker: Worker,
  link: WorkerLink,
  reason: StopReason,
  reply: Option(Subject(WorkerReport)),
) -> Result(WorkerState, Nil) {
  // Crash boundary: see `internal.rescue`. The topic closes in both cases.
  // A panic discards only the termination actions.
  let report = case internal.rescue(fn() { worker.on_terminate(reason) }) {
    Ok(effects) -> WorkerTerminated(effects, None)
    Error(crash) -> WorkerTerminated([], Some(crash))
  }
  case reply {
    Some(reply) -> process.send(reply, report)
    None -> link.report(report)
  }
  Error(Nil)
}

/// Run one callback inside the crash boundary and report its result.
///
/// A panic keeps the state from before the callback. The socket actor closes
/// the topic and runs `on_terminate` with that state. A `WorkerClose` result
/// also keeps the worker alive until it receives the termination request.
/// The worker accepts no other work while it waits.
fn worker_step(
  worker: Worker,
  link: WorkerLink,
  source: Source,
  callback: fn() -> socket.WorkerStep,
) -> WorkerState {
  // Crash boundary: see `internal.rescue`.
  case internal.rescue(callback) {
    Ok(socket.WorkerContinue(next, effects)) -> {
      link.report(WorkerRan(effects, False, source))
      WorkerRunning(next, link)
    }
    Ok(socket.WorkerClose(effects)) -> {
      link.report(WorkerRan(effects, True, source))
      WorkerClosing(worker, link)
    }
    Error(crash) -> {
      link.report(WorkerCrashed(crash, source))
      WorkerClosing(worker, link)
    }
  }
}

/// Start the worker for a join and answer the join from its outcome.
///
/// The contract's `accepts` runs first: a refused topic is rejected with
/// its reason and no worker is spawned.
///
/// The accept-time effects are lowered behind the `AcceptJoin` in the
/// same list, so the acknowledgment precedes the join's own pushes and
/// the subscription exists when they are applied.
fn execute_worker_join(
  state: State(model, message),
  socket_id: String,
  socket: SocketState(model, message),
  workers: TopicWorkers,
  topic_name: String,
  payload: Dynamic,
  ref: JoinRef,
  source: Source,
  continuation: Continuation,
) -> Execution(model, message) {
  case workers.accepts(topic_name) {
    Error(reason) ->
      execute_update_result(
        state,
        socket_id,
        source,
        continuation,
        Ok(socket.Next(socket.model, [socket.RejectJoin(ref, reason)])),
      )
    Ok(Nil) ->
      execute_accepted_worker_join(
        state,
        socket_id,
        socket,
        workers.factory,
        topic_name,
        payload,
        ref,
        source,
        continuation,
      )
  }
}

fn execute_accepted_worker_join(
  state: State(model, message),
  socket_id: String,
  socket: SocketState(model, message),
  factory: factory_supervisor.Supervisor(WorkerSpawn, WorkerStarted),
  topic_name: String,
  payload: Dynamic,
  ref: JoinRef,
  source: Source,
  continuation: Continuation,
) -> Execution(model, message) {
  let spawn =
    WorkerSpawn(
      socket_id: socket_id,
      seed: socket.seed,
      topic: topic_name,
      payload: payload,
    )
  let #(state, result) = case factory_supervisor.start_child(factory, spawn) {
    Ok(actor.Started(pid:, data: #(subject, Ok(#(reply, effects))))) -> {
      let worker = WorkerRef(subject:, pid:, monitor: process.monitor(pid))
      let state =
        store_socket(
          state,
          SocketState(
            ..socket,
            workers: dict.insert(socket.workers, topic_name, worker),
          ),
        )
      #(
        state,
        Ok(
          socket.Next(socket.model, [socket.AcceptJoin(ref, reply), ..effects]),
        ),
      )
    }
    Ok(actor.Started(data: #(_, Error(reason)), ..)) -> #(
      state,
      Ok(socket.Next(socket.model, [socket.RejectJoin(ref, reason)])),
    )
    // A panicking `join` failed the start with the crash boundary's
    // bounded description; the other failures are described here.
    Error(actor.InitFailed(crash)) -> #(state, Error(crash))
    Error(actor.InitTimeout) -> #(
      state,
      Error(
        "join did not finish within "
        <> int.to_string(worker_join_timeout_ms)
        <> "ms",
      ),
    )
    Error(actor.InitExited(reason)) -> #(
      state,
      Error(exit_reason_to_string(reason)),
    )
  }
  execute_update_result(state, socket_id, source, continuation, result)
}

/// Let a joined topic worker handle its mailbox.
///
/// The runtime has indexed the join. Thus, actions from the worker can reach
/// the topic subscribers. This includes mail that `join` sent to itself.
fn release_worker(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
) -> Nil {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> Nil
    Ok(socket) ->
      case dict.get(socket.workers, topic_name) {
        Ok(worker) -> process.send(worker.subject, WorkerGo)
        Error(Nil) -> Nil
      }
  }
}

/// Apply a worker's report if the worker still owns its topic.
fn handle_worker_report(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  pid: Pid,
  report: WorkerReport,
) -> State(model, message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket) ->
      case dict.get(socket.workers, topic_name) {
        Ok(WorkerRef(pid: owner, ..)) if owner == pid ->
          run(state, socket_id, [StepWorkerReport(topic_name, report)])
        Ok(WorkerRef(..)) | Error(Nil) -> {
          state.logger
          |> log.debug("Worker report dropped: worker no longer owns topic", [
            #("socket_id", socket_id),
            #("topic", topic_name),
          ])
          state
        }
      }
  }
}

fn execute_worker_report(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  report: WorkerReport,
) -> Execution(model, message) {
  case report {
    WorkerRan(effects, closing, source) -> {
      // Convert a worker close request to a kick, as the shared interpreter
      // did. Do not add the kick when the topic is already closing because it
      // would produce a no-op warning.
      let effects = case
        closing && socket_subscribed(state, socket_id, topic_name)
      {
        True -> list.append(effects, [socket.KickTopic(topic_name)])
        False -> effects
      }
      Continue(state, [
        StepEffects(
          effects,
          None,
          [],
          ContinueFinishingUpdate(source, effects, ContinueDriving),
        ),
      ])
    }
    WorkerCrashed(crash, source) ->
      execute_update_crash(state, socket_id, source, ContinueDriving, crash)
    // Only meaningful as the event a parked socket is waiting for.
    WorkerTerminated(..) -> Continue(state, [])
  }
}

/// Handle a worker that stopped.
///
/// If an active worker stops, close its topic with an error. The runtime
/// cannot run `on_terminate` because the worker held the channel state. The
/// `phx_error` tells the client to rejoin.
fn handle_worker_down(
  state: State(model, message),
  socket_id: String,
  down: process.Down,
) -> State(model, message) {
  case down, dict.get(state.sockets, socket_id) {
    process.PortDown(..), Ok(_)
    | process.PortDown(..), Error(Nil)
    | process.ProcessDown(..), Error(Nil)
    -> state
    process.ProcessDown(pid:, reason:, ..), Ok(socket) -> {
      let owned =
        dict.to_list(socket.workers)
        |> list.find(fn(entry) { { entry.1 }.pid == pid })
      case owned {
        // Its close already finished, or it was never this socket's.
        Error(Nil) -> state
        Ok(#(topic_name, _)) -> {
          let exit = exit_reason_to_string(reason)
          state.logger
          |> log.error("Topic worker exited; closing topic", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("reason", exit),
          ])
          let state =
            store_socket(
              state,
              SocketState(
                ..socket,
                workers: dict.delete(socket.workers, topic_name),
              ),
            )
          run(state, socket_id, [
            StepCloseTopic(
              topic_name,
              socket.Errored("worker exited: " <> exit),
              ContinueDriving,
            ),
          ])
        }
      }
    }
  }
}

/// Route a close to the topic's worker.
///
/// Usually, the socket waits asynchronously for the worker to terminate.
///
/// During shutdown, the socket cannot resume another turn. It uses a bounded
/// synchronous receive on a reply subject that the worker answers directly.
fn close_worker_topic(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  worker: WorkerRef,
  close_join_ref: Option(String),
  reason: StopReason,
  continuation: Continuation,
) -> Execution(model, message) {
  // A stopped worker has no termination callback to run. Its `Down` message
  // can still be queued or not yet received. Continue the close without
  // waiting for the termination timeout.
  use <- bool.lazy_guard(when: !process.is_alive(worker.pid), return: fn() {
    state.logger
    |> log.error("Topic worker already exited; closing without on_terminate", [
      #("socket_id", socket_id),
      #("topic", topic_name),
    ])
    process.demonitor_process(worker.monitor)
    Continue(state, [
      StepEffects(
        [],
        None,
        [],
        ContinueClosingTopic(topic_name, close_join_ref, reason, continuation),
      ),
    ])
  })
  case state.stopping {
    False -> {
      process.send(worker.subject, WorkerTerminate(reason, None))
      let timer =
        process.send_after(
          state.self_subject,
          worker_terminate_timeout_ms,
          WorkerTerminateTimedOut(socket_id, worker.pid),
        )
      Await(
        state,
        WorkerWait(topic_name, worker, close_join_ref, reason, continuation),
        timer,
        [],
      )
    }
    True -> {
      let reply = process.new_subject()
      process.send(worker.subject, WorkerTerminate(reason, Some(reply)))
      let received =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(worker.monitor, Error)
        |> process.selector_receive(worker_terminate_timeout_ms)
      let effects = case received {
        Ok(Ok(WorkerTerminated(effects, crash))) -> {
          log_terminate_crash(state, socket_id, topic_name, crash)
          effects
        }
        // The worker answers this subject only from `WorkerTerminate`;
        // callback results always go to the socket actor's mailbox.
        Ok(Ok(WorkerRan(..))) | Ok(Ok(WorkerCrashed(..))) -> []
        // It exited before it could report.
        Ok(Error(down)) -> {
          log_worker_exit(state, socket_id, topic_name, down)
          []
        }
        Error(Nil) -> {
          kill_stuck_worker(state, socket_id, topic_name, worker)
          []
        }
      }
      process.demonitor_process(worker.monitor)
      Continue(state, [
        StepEffects(
          effects,
          None,
          [],
          ContinueClosingTopic(topic_name, close_join_ref, reason, continuation),
        ),
      ])
    }
  }
}

/// Finish a topic close when `message` reports the expected worker
/// termination. Return `None` for a different message.
///
/// The queue contains results that the worker reported before termination.
/// These results can use reply refs that the close has not removed. Apply
/// them in order, and then continue the close.
fn resume_worker_close(
  state: State(model, message),
  socket_id: String,
  suspension: Suspension(message),
  message: Message(message),
) -> Option(State(model, message)) {
  case suspension.waiting {
    PresenceWait(..) -> None
    WorkerWait(topic_name, worker, close_join_ref, reason, continuation) -> {
      let awaited = worker.pid
      use effects <- option.map(worker_termination_effects(
        state,
        socket_id,
        topic_name,
        worker,
        message,
      ))
      let _cancelled = process.cancel_timer(suspension.timer)
      process.demonitor_process(worker.monitor)
      // The queue is newest-first, so prepending while folding it leaves
      // both halves oldest-first.
      let #(in_flight, others) =
        dict.get(state.queued, socket_id)
        |> result.unwrap([])
        |> list.fold(#([], []), fn(split, message) {
          case message {
            WorkerReport(worker: pid, report:, ..) if pid == awaited -> #(
              [StepWorkerReport(topic_name, report), ..split.0],
              split.1,
            )
            WorkerReport(..)
            | AdmitSocket(..)
            | SocketDisconnected(..)
            | RouteText(..)
            | RouteDecoded(..)
            | RouteDecodedBinary(..)
            | HandleBinary(..)
            | AppInfo(..)
            | Broadcast(..)
            | RemoteBroadcast(..)
            | CheckHeartbeats
            | GetStats(..)
            | PresenceAcknowledged(..)
            | PresenceOperationTimedOut(..)
            | Stop(..)
            | IndexJoin(..)
            | IndexLeave(..)
            | SocketClosed(..)
            | RouterDown
            | SocketActorDown(..)
            | StopSocketActor
            | StopTimedOut
            | FinalizeForStop
            | StopPhaseDone
            | WorkerDown(..)
            | WorkerTerminateTimedOut(..)
            | BootTimedOut -> #(split.0, [message, ..split.1])
          }
        })
      let state =
        State(
          ..state,
          suspended: dict.delete(state.suspended, socket_id),
          queued: case others {
            [] -> dict.delete(state.queued, socket_id)
            _ -> dict.insert(state.queued, socket_id, list.reverse(others))
          },
        )
      let steps =
        list.append(in_flight, [
          StepEffects(
            effects,
            None,
            [],
            ContinueClosingTopic(
              topic_name,
              close_join_ref,
              reason,
              continuation,
            ),
          ),
          ..suspension.stack
        ])
      drain_queue(run(state, socket_id, steps), socket_id)
    }
  }
}

fn worker_termination_effects(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  worker: WorkerRef,
  message: Message(message),
) -> Option(List(Effect)) {
  let awaited = worker.pid
  case message {
    WorkerReport(worker: pid, report: WorkerTerminated(effects, crash), ..)
      if pid == awaited
    -> {
      log_terminate_crash(state, socket_id, topic_name, crash)
      Some(effects)
    }
    WorkerDown(process.ProcessDown(pid:, ..) as down) if pid == awaited -> {
      log_worker_exit(state, socket_id, topic_name, down)
      Some([])
    }
    WorkerTerminateTimedOut(worker: pid, ..) if pid == awaited -> {
      kill_stuck_worker(state, socket_id, topic_name, worker)
      Some([])
    }
    WorkerReport(..)
    | WorkerDown(..)
    | WorkerTerminateTimedOut(..)
    | AdmitSocket(..)
    | SocketDisconnected(..)
    | RouteText(..)
    | RouteDecoded(..)
    | RouteDecodedBinary(..)
    | HandleBinary(..)
    | AppInfo(..)
    | Broadcast(..)
    | RemoteBroadcast(..)
    | CheckHeartbeats
    | GetStats(..)
    | PresenceAcknowledged(..)
    | PresenceOperationTimedOut(..)
    | Stop(..)
    | IndexJoin(..)
    | IndexLeave(..)
    | SocketClosed(..)
    | RouterDown
    | SocketActorDown(..)
    | StopSocketActor
    | StopTimedOut
    | FinalizeForStop
    | StopPhaseDone
    | BootTimedOut -> None
  }
}

fn log_worker_exit(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  down: process.Down,
) -> Nil {
  let reason = case down {
    process.ProcessDown(reason:, ..) | process.PortDown(reason:, ..) -> reason
  }
  state.logger
  |> log.error("Topic worker exited while closing", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("reason", exit_reason_to_string(reason)),
  ])
}

fn kill_stuck_worker(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  worker: WorkerRef,
) -> Nil {
  state.logger
  |> log.error(
    "Topic worker did not finish its queued work and on_terminate in time; killing it",
    [
      #("socket_id", socket_id),
      #("topic", topic_name),
      #("timeout_ms", int.to_string(worker_terminate_timeout_ms)),
    ],
  )
  process.kill(worker.pid)
}

fn log_terminate_crash(
  state: State(model, message),
  socket_id: String,
  topic_name: String,
  crash: Option(String),
) -> Nil {
  case crash {
    None -> Nil
    Some(crash) ->
      state.logger
      |> log.error("Update crashed handling closed", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("crash", crash),
      ])
  }
}
