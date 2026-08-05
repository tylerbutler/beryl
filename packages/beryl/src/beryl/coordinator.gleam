//// Coordinator - Central actor for channel management
////
//// This actor manages:
//// - Channel handler registration (pattern -> handler)
//// - Socket tracking (socket_id -> send function)
//// - Topic subscriptions (topic -> set of socket_ids)
//// - Message routing and broadcasting
//// - Heartbeat timeout enforcement

import beryl/channel.{type StopReason}
import beryl/internal
import beryl/log.{type Logger}
import beryl/pubsub.{type PubSub}
import beryl/rate_limit.{type RateLimitConfig}
import beryl/telemetry
import beryl/topic.{type TopicPattern}
import beryl/wire/codec.{type Codec}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// Type-erased channel handler template stored in the registry.
///
/// Only `join` lives on the template: a successful join returns a
/// `JoinedChannel` instance whose closures capture the channel's typed
/// assigns, and every later callback for that socket/topic runs on the
/// stored instance. The third `join` argument is the connect-time assigns
/// seeded (type-erased) by the transport's connect hook.
pub type ChannelHandler {
  ChannelHandler(
    id: Int,
    pattern: TopicPattern,
    join: fn(String, Dynamic, Dynamic, SocketContext) -> JoinResultErased,
  )
}

/// A joined channel instance.
///
/// The closures capture the channel's current typed assigns, so the
/// coordinator threads state between callbacks by storing the `next`
/// instance each callback returns — no assigns value crosses this boundary
/// type-erased. `handle_info` receives the erased server message sent via
/// `beryl.send_info`; the id check in `HandleInfo` dispatch guarantees it
/// was erased from this channel's info type.
pub type JoinedChannel {
  JoinedChannel(
    handle_in: fn(String, Dynamic, SocketContext) -> HandleResultErased,
    handle_binary: fn(BitArray, SocketContext) -> HandleResultErased,
    handle_info: fn(Dynamic, SocketContext) -> HandleResultErased,
    terminate: fn(StopReason, SocketContext) -> Nil,
  )
}

/// Context passed to handlers (replaces Socket in erased form)
pub type SocketContext {
  SocketContext(
    socket_id: String,
    topic: String,
    /// Function to send text messages to this socket
    send: fn(String) -> Result(Nil, Nil),
    /// Function to send binary data to this socket
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    /// Ask the transport to close this socket's connection
    close: fn() -> Nil,
  )
}

/// Type-erased join result
pub type JoinResultErased {
  JoinOkErased(reply: Option(json.Json), channel: JoinedChannel)
  JoinErrorErased(reason: json.Json)
}

/// Type-erased handle result. Each non-terminal variant carries the next
/// channel instance, with the updated assigns captured in its closures.
pub type HandleResultErased {
  NoReplyErased(next: JoinedChannel)
  ReplyErased(event: String, payload: json.Json, next: JoinedChannel)
  ReplyErrorErased(payload: json.Json, next: JoinedChannel)
  PushErased(event: String, payload: json.Json, next: JoinedChannel)
  StopErased(reason: StopReason)
}

/// A point-in-time view of coordinator-owned state.
///
/// This type is internal to the coordinator protocol. Applications use the
/// opaque snapshot and accessors in `beryl/stats`.
pub type StatsSnapshot {
  StatsSnapshot(
    connected_sockets: Int,
    joined_socket_topic_pairs: Int,
    active_topics: Int,
    registered_channel_handlers: Int,
    coordinator_mailbox_length: Int,
  )
}

/// Errors when registering channels
pub type RegisterError {
  PatternAlreadyRegistered(String)
  /// The pattern failed `topic.validate_pattern` (empty or contains control
  /// characters).
  InvalidPattern(String)
}

/// Errors when starting the coordinator
pub type StartError {
  /// heartbeat_timeout_ms must be > 0 when heartbeat checking is enabled
  InvalidHeartbeatTimeout
  /// The underlying OTP actor failed to start
  ActorStartFailed(actor.StartError)
}

/// Logging verbosity for the coordinator's internal logger.
pub type LogLevel {
  Debug
  Info
  Warn
  Err
}

/// Logging configuration for coordinator diagnostics.
pub type LoggingConfig {
  LoggingConfig(
    level: LogLevel,
    include_payloads: Bool,
    payload_preview_bytes: Int,
  )
}

/// Configuration for heartbeat enforcement
pub type CoordinatorConfig {
  CoordinatorConfig(
    /// Wire codec used to decode inbound text frames and encode replies/pushes.
    codec: Codec,
    /// How often to check for stale sockets, in milliseconds.
    /// Set to 0 to disable automatic heartbeat checking.
    heartbeat_check_interval_ms: Int,
    /// Disconnect sockets that haven't sent a heartbeat within this duration
    heartbeat_timeout_ms: Int,
    /// Per-socket message rate limits (None = unlimited)
    message_limits: Option(RateLimitConfig),
    /// Per-socket join rate limits (None = unlimited)
    join_limits: Option(RateLimitConfig),
    /// Per-channel message rate limits (None = unlimited)
    channel_limits: Option(RateLimitConfig),
    /// Maximum active channel-limiter buckets per socket. Values <= 0 disable the cap.
    channel_limiter_max_keys_per_socket: Int,
    /// Maximum byte length for client-supplied topic strings (default: 256).
    /// Topics exceeding this limit are rejected before reaching a channel handler.
    max_topic_length: Int,
    /// Maximum byte length for client-supplied event name strings (default: 64).
    /// Events exceeding this limit are dropped before reaching a channel handler.
    max_event_length: Int,
    /// Maximum joined topics per socket. Values <= 0 disable the cap.
    max_joined_topics_per_socket: Int,
    /// Whether internal telemetry events are enabled.
    telemetry: Bool,
    /// Logging configuration for coordinator diagnostics.
    logging: LoggingConfig,
    /// Optional crash-survivable handler registry. When set, the
    /// coordinator seeds its handler table from the registry at init, so a
    /// supervised restart recovers every registration.
    registry: Option(Registry),
  )
}

/// Build a coordinator configuration. A codec is required — use
/// `wire.phoenix_codec()` for the historical Phoenix array format, or
/// supply your own `Codec` value.
pub fn config(codec: Codec) -> CoordinatorConfig {
  CoordinatorConfig(
    codec: codec,
    heartbeat_check_interval_ms: 0,
    heartbeat_timeout_ms: 60_000,
    message_limits: None,
    join_limits: None,
    channel_limits: None,
    channel_limiter_max_keys_per_socket: 1000,
    max_topic_length: 256,
    max_event_length: 64,
    max_joined_topics_per_socket: 1000,
    telemetry: False,
    logging: LoggingConfig(
      level: Info,
      include_payloads: False,
      payload_preview_bytes: 200,
    ),
    registry: None,
  )
}

fn internal_logging(config: LoggingConfig) -> internal.LoggingConfig {
  internal.LoggingConfig(
    level: case config.level {
      Debug -> internal.Debug
      Info -> internal.Info
      Warn -> internal.Warn
      Err -> internal.Err
    },
    include_payloads: config.include_payloads,
    payload_preview_bytes: config.payload_preview_bytes,
  )
}

fn coordinator_logger(state: State) -> Logger {
  state.logger
}

fn optional_string(value: Option(String)) -> String {
  value
  |> option.unwrap("")
  |> topic.sanitize_for_log
}

fn inbound_kind(kind: codec.InboundKind) -> String {
  case kind {
    codec.Join -> "join"
    codec.Leave -> "leave"
    codec.Heartbeat -> "heartbeat"
    codec.Event(event) -> event
  }
}

fn stop_reason(reason: channel.StopReason) -> String {
  case reason {
    channel.Normal -> "normal"
    channel.Shutdown -> "shutdown"
    channel.HeartbeatTimeout -> "heartbeat_timeout"
    channel.Errored(message) -> message
  }
}

fn joined_topics_metadata(socket_info: SocketInfo) -> List(#(String, String)) {
  let topics = set.to_list(socket_info.subscribed_topics)
  [
    #("joined_topic_count", int.to_string(list.length(topics))),
    #("joined_topics", string.join(topics, ",")),
  ]
}

/// Internal state for coordinator actor
type State {
  State(
    /// Pattern -> handler (ordered list for matching)
    handlers: List(ChannelHandler),
    /// Next unique id assigned to a registered channel handler.
    next_handler_id: Int,
    /// Socket ID -> socket info
    sockets: Dict(String, SocketInfo),
    /// Topic -> set of socket IDs subscribed
    topics: Dict(String, Set(String)),
    /// Heartbeat timeout configuration
    config: CoordinatorConfig,
    /// Optional PubSub for distributed broadcasts
    pubsub: Option(PubSub(json.Json)),
    /// Configured coordinator logger, cached for hot message paths.
    logger: Logger,
    /// The coordinator's own subject, used for scheduling timers
    self_subject: Option(Subject(Message)),
    /// Per-socket message-rate token buckets (socket_id -> bucket).
    message_buckets: Dict(String, rate_limit.Bucket),
    /// Per-socket join-rate token buckets (socket_id -> bucket).
    join_buckets: Dict(String, rate_limit.Bucket),
    /// Per-channel token buckets (socket_id -> topic -> bucket). Keyed by
    /// socket first so the per-socket cap and disconnect cleanup are O(1)
    /// lookups instead of prefix scans.
    channel_buckets: Dict(String, Dict(String, rate_limit.Bucket)),
  )
}

/// Info tracked per socket
type SocketInfo {
  SocketInfo(
    id: String,
    /// Function to send text to this socket's WebSocket
    send: fn(String) -> Result(Nil, Nil),
    /// Function to send binary to this socket's WebSocket
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    /// Ask the transport to close this socket's connection. Registered by
    /// the transport via `RegisterCloser`; a no-op until then.
    close: fn() -> Nil,
    /// Wire codec negotiated for this connection. Used to decode inbound
    /// binary frames and encode replies/pushes destined for this socket, so
    /// different connections can use different serializers concurrently.
    codec: Codec,
    /// Topics this socket is subscribed to
    subscribed_topics: Set(String),
    /// Per-topic joined channel instance (topic -> instance). The instance's
    /// closures capture the channel's current typed assigns.
    channel_instances: Dict(String, JoinedChannel),
    /// Per-topic registered channel id (topic -> handler id)
    channel_ids: Dict(String, Int),
    /// Per-topic join_ref from the accepted `phx_join` (topic -> join_ref).
    /// Used to echo the channel's join_ref in replies/terminal frames and to
    /// drop messages from a stale channel instance after a rejoin.
    join_refs: Dict(String, Option(String)),
    /// Socket-level assigns seeded by the transport connect hook (type-erased).
    /// Used as the initial assigns visible to a channel at join time.
    connect_assigns: Dynamic,
    /// Monotonic timestamp (ms) of the last heartbeat received
    last_heartbeat: Int,
    /// Native monotonic timestamp captured when the socket was accepted.
    connected_at: Int,
  )
}

/// Start a coordinator telemetry operation without touching the VM clock when
/// telemetry is disabled. Zero is a sentinel that is never observed by an
/// enabled operation.
fn telemetry_start(state: State) -> Int {
  use <- bool.guard(when: !state.config.telemetry, return: 0)
  telemetry.start_time()
}

fn emit_join_stop(
  state: State,
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
  state: State,
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
    channel.Normal -> telemetry.NormalDisconnect
    channel.Shutdown -> telemetry.ShutdownDisconnect
    channel.HeartbeatTimeout -> telemetry.HeartbeatTimeout
    channel.Errored(_) -> telemetry.CallbackDisconnect
  }
}

fn send_frame(socket_info: SocketInfo, frame: codec.Frame) -> Result(Nil, Nil) {
  case frame {
    codec.TextFrame(text) -> socket_info.send(text)
    codec.BinaryFrame(data) -> socket_info.send_binary(data)
  }
}

fn frame_kind(frame: codec.Frame) -> String {
  case frame {
    codec.TextFrame(_) -> "text"
    codec.BinaryFrame(_) -> "binary"
  }
}

fn send_frame_logged(
  state: State,
  socket_info: SocketInfo,
  topic_name: String,
  frame: codec.Frame,
) -> Result(Nil, Nil) {
  let result = send_frame(socket_info, frame)
  let logger = coordinator_logger(state)
  case result {
    Ok(Nil) ->
      logger
      |> log.debug("Outbound frame sent", [
        #("socket_id", socket_info.id),
        #("topic", topic_name),
        #("frame_kind", frame_kind(frame)),
      ])
    Error(Nil) ->
      logger
      |> log.warn("Outbound frame failed", [
        #("socket_id", socket_info.id),
        #("topic", topic_name),
        #("frame_kind", frame_kind(frame)),
      ])
  }
  result
}

/// Messages the coordinator handles
pub type Message {
  // Channel registration
  RegisterChannel(
    pattern: String,
    handler: ChannelHandler,
    reply: Subject(Result(Int, RegisterError)),
  )
  /// Replace the handler table with a registry snapshot. Sent by
  /// `beryl.register` after a registry write so the new registration
  /// reaches the live coordinator; the reply confirms visibility. Do not
  /// mix with direct `RegisterChannel` on the same coordinator — the
  /// snapshot replaces the whole table.
  SyncHandlers(
    handlers: List(ChannelHandler),
    next_handler_id: Int,
    reply: Subject(Nil),
  )
  // Socket lifecycle
  SocketConnected(
    socket_id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    /// Wire codec negotiated for this connection. `None` falls back to the
    /// coordinator's configured codec, preserving the historical behavior for
    /// callers that don't negotiate a per-connection serializer.
    codec: Option(Codec),
    /// Socket-level assigns seeded by the transport's connect hook
    /// (type-erased). Use `dynamic.nil()` when there are none.
    connect_assigns: Dynamic,
  )
  SocketDisconnected(socket_id: String)
  /// Register a function that closes the socket's underlying connection.
  /// Transports send this after `SocketConnected` so the coordinator can
  /// actively close connections it evicts (e.g. heartbeat timeout) instead
  /// of leaving zombie sockets whose frames are silently dropped.
  RegisterCloser(socket_id: String, close: fn() -> Nil)
  // Channel operations
  HandleBinary(socket_id: String, data: BitArray)
  HandleInfo(
    socket_id: String,
    topic: String,
    channel_id: Int,
    /// Server message erased from the registered channel's info type by
    /// `beryl.send_info`. Dispatch verifies `channel_id` against the joined
    /// instance before the instance's `handle_info` restores the type.
    message: Dynamic,
  )
  /// Raw inbound text from the transport, decoded inside the actor using
  /// the configured codec.
  RouteText(socket_id: String, raw_text: String)
  /// A decoded text message. Kept for compatibility with existing transport
  /// SPI callers; decoded binary frames use `RouteDecodedBinary`.
  RouteDecoded(socket_id: String, msg: codec.Inbound)
  /// A decoded binary message whose frame kind must survive routing for
  /// channel-message telemetry.
  RouteDecodedBinary(socket_id: String, msg: codec.Inbound)
  // Broadcasting
  Broadcast(
    topic: String,
    event: String,
    payload: json.Json,
    except: Option(String),
  )
  RemoteBroadcast(pubsub.Message(json.Json))
  /// Request a local, point-in-time snapshot of coordinator-owned state.
  GetStats(reply: Subject(StatsSnapshot))
  // Heartbeat timeout enforcement
  CheckHeartbeats
  Stop(reply: Subject(Nil))
}

/// Erlang monotonic time in milliseconds
@external(erlang, "beryl_ffi", "monotonic_time_ms")
fn monotonic_time_ms() -> Int

// ── Handler registry ────────────────────────────────────────────────────────

/// A crash-survivable store for channel registrations.
///
/// Registrations live outside the coordinator so a coordinator restart can
/// re-seed its handler table instead of coming back empty — which would
/// fail every join with `no_channel_handler` until the application itself
/// restarted. In the supervised tree the registry starts before the
/// coordinator, so a rest-for-one coordinator restart leaves it untouched.
pub opaque type Registry {
  Registry(subject: Subject(RegistryMsg))
}

/// Messages the registry actor handles. Opaque: use `registry_put` and the
/// coordinator's seeding; the type is public only so names can be created
/// for supervised registries.
pub opaque type RegistryMsg {
  RegistryPut(
    pattern: String,
    handler: ChannelHandler,
    reply: Subject(Result(Int, RegisterError)),
  )
  RegistrySnapshot(reply: Subject(#(List(ChannelHandler), Int)))
  RegistryStop(reply: Subject(Nil))
}

type RegistryState {
  RegistryState(handlers: List(ChannelHandler), next_id: Int)
}

fn handle_registry_msg(
  state: RegistryState,
  msg: RegistryMsg,
) -> actor.Next(RegistryState, RegistryMsg) {
  case msg {
    RegistryPut(pattern, handler, reply) ->
      case add_handler(state.handlers, state.next_id, pattern, handler) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(#(handlers, next_id, handler_id)) -> {
          process.send(reply, Ok(handler_id))
          actor.continue(RegistryState(handlers: handlers, next_id: next_id))
        }
      }
    RegistrySnapshot(reply) -> {
      process.send(reply, #(state.handlers, state.next_id))
      actor.continue(state)
    }
    RegistryStop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

/// Start an unsupervised handler registry.
pub fn start_registry() -> Result(Registry, actor.StartError) {
  actor.new(RegistryState(handlers: [], next_id: 0))
  |> actor.on_message(handle_registry_msg)
  |> actor.start
  |> result.map(fn(started) { Registry(subject: started.data) })
}

/// Start a handler registry with a registered name (for supervision).
pub fn start_registry_named(
  name: process.Name(RegistryMsg),
) -> Result(actor.Started(Subject(RegistryMsg)), actor.StartError) {
  actor.new(RegistryState(handlers: [], next_id: 0))
  |> actor.on_message(handle_registry_msg)
  |> actor.named(name)
  |> actor.start
}

/// Build a registry handle from a registered name.
pub fn registry_from_name(name: process.Name(RegistryMsg)) -> Registry {
  Registry(subject: process.named_subject(name))
}

/// Validate and store a registration, returning its assigned handler id.
///
/// Panics if the registry is unavailable or does not reply within 5
/// seconds, matching `beryl.register`'s contract.
pub fn registry_put(
  registry: Registry,
  pattern: String,
  handler: ChannelHandler,
) -> Result(Int, RegisterError) {
  process.call(registry.subject, 5000, fn(reply) {
    RegistryPut(pattern, handler, reply)
  })
}

/// Read the registry's full handler table and next id. Falls back to an
/// empty table when the registry is unavailable, so a coordinator can still
/// start (with a logged snapshot of nothing) rather than crash-loop.
pub fn registry_snapshot(registry: Registry) -> #(List(ChannelHandler), Int) {
  case process.subject_owner(registry.subject) {
    Error(Nil) -> #([], 0)
    Ok(_) -> {
      let reply_subject = process.new_subject()
      process.send(registry.subject, RegistrySnapshot(reply_subject))
      case process.receive(reply_subject, 1000) {
        Ok(snapshot) -> snapshot
        Error(Nil) -> #([], 0)
      }
    }
  }
}

/// Stop an unsupervised registry.
pub fn stop_registry(registry: Registry) -> Nil {
  let should_send = case process.subject_owner(registry.subject) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
  use <- bool.guard(when: !should_send, return: Nil)
  let reply = process.new_subject()
  process.send(registry.subject, RegistryStop(reply))
  let _stop_result = process.receive(reply, 1000)
  Nil
}

/// Start the coordinator actor with default heartbeat settings (no checking),
/// using the supplied wire codec.
pub fn start(codec: Codec) -> Result(Subject(Message), StartError) {
  start_with_config(config(codec))
}

/// Start the coordinator actor with heartbeat timeout enforcement
pub fn start_with_config(
  config: CoordinatorConfig,
) -> Result(Subject(Message), StartError) {
  use _ <- result.try(validate_config(config))
  build_coordinator(config, None)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(ActorStartFailed)
}

/// Start the coordinator actor with heartbeat timeout enforcement and PubSub.
pub fn start_with_config_and_pubsub(
  config: CoordinatorConfig,
  ps: PubSub(json.Json),
) -> Result(Subject(Message), StartError) {
  use _ <- result.try(validate_config(config))
  build_coordinator(config, Some(ps))
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(ActorStartFailed)
}

/// Start the coordinator with a registered name (for supervision)
pub fn start_named(
  config: CoordinatorConfig,
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), StartError) {
  use _ <- result.try(validate_config(config))
  build_coordinator(config, None)
  |> actor.named(name)
  |> actor.start
  |> result.map_error(ActorStartFailed)
}

/// Start a named coordinator actor with PubSub.
pub fn start_named_with_pubsub(
  config: CoordinatorConfig,
  ps: PubSub(json.Json),
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), StartError) {
  use _ <- result.try(validate_config(config))
  build_coordinator(config, Some(ps))
  |> actor.named(name)
  |> actor.start
  |> result.map_error(ActorStartFailed)
}

fn validate_config(config: CoordinatorConfig) -> Result(Nil, StartError) {
  use <- bool.guard(
    when: config.heartbeat_check_interval_ms > 0
      && config.heartbeat_timeout_ms <= 0,
    return: Error(InvalidHeartbeatTimeout),
  )
  Ok(Nil)
}

fn build_coordinator(
  config: CoordinatorConfig,
  ps: Option(PubSub(json.Json)),
) -> actor.Builder(State, Message, Subject(Message)) {
  let logging = internal_logging(config.logging)
  internal.configure(logging)
  // Seed the handler table from the registry (empty when none is
  // configured), so a supervised restart recovers every registration.
  let #(seeded_handlers, seeded_next_id) = case config.registry {
    Some(registry) -> registry_snapshot(registry)
    None -> #([], 0)
  }
  let initial_state =
    State(
      handlers: seeded_handlers,
      next_handler_id: seeded_next_id,
      sockets: dict.new(),
      topics: dict.new(),
      config: config,
      pubsub: ps,
      logger: internal.logger_with_config("beryl.coordinator", logging),
      self_subject: None,
      message_buckets: dict.new(),
      join_buckets: dict.new(),
      channel_buckets: dict.new(),
    )

  actor.new_with_initialiser(5000, fn(subject) {
    let state = State(..initial_state, self_subject: Some(subject))

    // Schedule the first heartbeat check if configured
    schedule_heartbeat_check(subject, config)

    let initialised = actor.initialised(state) |> actor.returning(subject)

    case ps {
      Some(_) -> {
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> pubsub.selecting(RemoteBroadcast)

        initialised
        |> actor.selecting(selector)
        |> Ok
      }
      None -> Ok(initialised)
    }
  })
  |> actor.on_message(handle_message)
}

/// Schedule the next heartbeat check timer
fn schedule_heartbeat_check(
  subject: Subject(Message),
  config: CoordinatorConfig,
) -> Nil {
  use <- bool.guard(when: config.heartbeat_check_interval_ms <= 0, return: Nil)
  let _timer =
    process.send_after(
      subject,
      config.heartbeat_check_interval_ms,
      CheckHeartbeats,
    )
  Nil
}

/// Handle incoming messages
fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    RegisterChannel(pattern, handler, reply) ->
      handle_register_channel(state, pattern, handler, reply)

    SyncHandlers(handlers, next_handler_id, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        State(..state, handlers: handlers, next_handler_id: next_handler_id),
      )
    }

    SocketConnected(socket_id, send, send_binary, codec, connect_assigns) ->
      handle_socket_connected(
        state,
        socket_id,
        send,
        send_binary,
        codec,
        connect_assigns,
      )

    SocketDisconnected(socket_id) ->
      handle_socket_disconnected(state, socket_id)

    RegisterCloser(socket_id, close) ->
      handle_register_closer(state, socket_id, close)

    HandleBinary(socket_id, data) -> handle_binary_in(state, socket_id, data)

    HandleInfo(socket_id, topic_name, channel_id, info_message) ->
      handle_info(state, socket_id, topic_name, channel_id, info_message)

    RouteText(socket_id, raw_text) ->
      handle_route_text(state, socket_id, raw_text)

    RouteDecoded(socket_id, msg) ->
      dispatch_inbound(state, socket_id, msg, telemetry.TextMessage)

    RouteDecodedBinary(socket_id, msg) ->
      dispatch_inbound(state, socket_id, msg, telemetry.BinaryMessage)

    Broadcast(topic_name, event, payload, except) ->
      handle_broadcast(
        state,
        topic_name,
        event,
        payload,
        except,
        telemetry.Local,
      )

    RemoteBroadcast(pubsub_msg) ->
      // The pg-delivered record is coerced without validation, so a
      // malformed message (mixed-version cluster, stray tuple sent to the
      // coordinator's pid) must not crash the coordinator.
      case
        internal.rescue(fn() { handle_remote_broadcast(state, pubsub_msg) })
      {
        Ok(next) -> next
        Error(crash) -> {
          coordinator_logger(state)
          |> log.error("Remote broadcast dropped: malformed message", [
            #("crash", crash),
          ])
          actor.continue(state)
        }
      }

    GetStats(reply) -> handle_get_stats(state, reply)

    CheckHeartbeats -> handle_check_heartbeats(state)

    Stop(reply) -> handle_stop(state, reply)
  }
}

fn handle_get_stats(
  state: State,
  reply: Subject(StatsSnapshot),
) -> actor.Next(State, Message) {
  let joined_pairs =
    dict.fold(state.sockets, 0, fn(count, _socket_id, socket_info) {
      count + set.size(socket_info.subscribed_topics)
    })
  let active_topics =
    dict.fold(state.topics, 0, fn(count, _topic_name, subscribers) {
      case set.is_empty(subscribers) {
        True -> count
        False -> count + 1
      }
    })

  process.send(
    reply,
    StatsSnapshot(
      connected_sockets: dict.size(state.sockets),
      joined_socket_topic_pairs: joined_pairs,
      active_topics: active_topics,
      registered_channel_handlers: list.length(state.handlers),
      coordinator_mailbox_length: telemetry.mailbox_length(),
    ),
  )
  actor.continue(state)
}

fn handle_stop(
  state: State,
  reply: Subject(Nil),
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  logger
  |> log.info("Coordinator stopping", [
    #("socket_count", int.to_string(dict.size(state.sockets))),
  ])

  dict.keys(state.sockets)
  |> list.fold(state, fn(st, socket_id) {
    disconnect_socket(st, socket_id, channel.Shutdown)
  })

  process.send(reply, Nil)
  actor.stop()
}

fn handle_register_channel(
  state: State,
  pattern_str: String,
  handler: ChannelHandler,
  reply: Subject(Result(Int, RegisterError)),
) -> actor.Next(State, Message) {
  use <- bool.lazy_guard(
    when: result.is_error(topic.validate_pattern(pattern_str)),
    return: fn() {
      process.send(reply, Error(InvalidPattern(pattern_str)))
      actor.continue(state)
    },
  )
  case
    add_handler(state.handlers, state.next_handler_id, pattern_str, handler)
  {
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
    Ok(#(new_handlers, next_id, handler_id)) -> {
      process.send(reply, Ok(handler_id))
      actor.continue(
        State(..state, handlers: new_handlers, next_handler_id: next_id),
      )
    }
  }
}

/// Validate and append a handler to a handler table, assigning the next id.
/// Shared by the coordinator's direct registration path and the registry.
fn add_handler(
  handlers: List(ChannelHandler),
  next_id: Int,
  pattern_str: String,
  handler: ChannelHandler,
) -> Result(#(List(ChannelHandler), Int, Int), RegisterError) {
  use <- bool.guard(
    when: result.is_error(topic.validate_pattern(pattern_str)),
    return: Error(InvalidPattern(pattern_str)),
  )
  let pattern = topic.parse_pattern(pattern_str)
  let already_registered = list.any(handlers, fn(h) { h.pattern == pattern })
  use <- bool.guard(
    when: already_registered,
    return: Error(PatternAlreadyRegistered(pattern_str)),
  )
  let registered_handler =
    ChannelHandler(id: next_id, pattern: pattern, join: handler.join)
  Ok(#(list.append(handlers, [registered_handler]), next_id + 1, next_id))
}

fn handle_socket_connected(
  state: State,
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  codec: Option(Codec),
  connect_assigns: Dynamic,
) -> actor.Next(State, Message) {
  let socket_info =
    SocketInfo(
      id: socket_id,
      send: send,
      send_binary: send_binary,
      close: fn() { Nil },
      codec: option.unwrap(codec, state.config.codec),
      subscribed_topics: set.new(),
      channel_instances: dict.new(),
      channel_ids: dict.new(),
      join_refs: dict.new(),
      connect_assigns: connect_assigns,
      last_heartbeat: monotonic_time_ms(),
      connected_at: telemetry_start(state),
    )

  let logger = coordinator_logger(state)
  logger |> log.info("Socket connected", [#("socket_id", socket_id)])
  let new_sockets = dict.insert(state.sockets, socket_id, socket_info)
  telemetry.emit(state.config.telemetry, telemetry.SocketConnected)
  actor.continue(State(..state, sockets: new_sockets))
}

fn handle_register_closer(
  state: State,
  socket_id: String,
  close: fn() -> Nil,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> actor.continue(state)
    Ok(socket_info) -> {
      let new_sockets =
        dict.insert(
          state.sockets,
          socket_id,
          SocketInfo(..socket_info, close: close),
        )
      actor.continue(State(..state, sockets: new_sockets))
    }
  }
}

fn handle_socket_disconnected(
  state: State,
  socket_id: String,
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  let metadata = case dict.get(state.sockets, socket_id) {
    Ok(socket_info) ->
      list.append(
        [#("socket_id", socket_id)],
        joined_topics_metadata(socket_info),
      )
    Error(Nil) -> [#("socket_id", socket_id)]
  }
  logger |> log.info("Socket disconnected", metadata)
  actor.continue(disconnect_socket(state, socket_id, channel.Normal))
}

fn remove_socket_rate_limits(state: State, socket_id: String) -> State {
  State(
    ..state,
    message_buckets: dict.delete(state.message_buckets, socket_id),
    join_buckets: dict.delete(state.join_buckets, socket_id),
    channel_buckets: dict.delete(state.channel_buckets, socket_id),
  )
}

/// Take a token from the socket's message-rate bucket. Always allowed when
/// no message limits are configured.
fn check_message_rate(state: State, socket_id: String) -> #(State, Bool) {
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

/// Take a token from the socket's join-rate bucket. Always allowed when no
/// join limits are configured.
fn check_join_rate(state: State, socket_id: String) -> #(State, Bool) {
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

/// Take a token from the socket's per-topic channel bucket, refusing to
/// create a new bucket beyond the per-socket cap. Always allowed when no
/// channel limits are configured.
fn check_channel_rate(
  state: State,
  socket_id: String,
  topic_name: String,
) -> #(State, Bool) {
  case state.config.channel_limits {
    None -> #(state, True)
    Some(limits) -> take_channel_token(state, socket_id, topic_name, limits)
  }
}

fn take_channel_token(
  state: State,
  socket_id: String,
  topic_name: String,
  limits: RateLimitConfig,
) -> #(State, Bool) {
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

/// Drop the channel bucket for a terminated socket/topic pair.
fn remove_channel_bucket(
  state: State,
  socket_id: String,
  topic_name: String,
) -> State {
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

fn handle_join(
  state: State,
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State, Message) {
  // Check join rate limit
  let #(state, join_allowed) = check_join_rate(state, socket_id)
  case join_allowed {
    False -> {
      let logger = coordinator_logger(state)
      logger
      |> log.warn("Join rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      // Send error reply to client
      case dict.get(state.sockets, socket_id) {
        Ok(socket_info) -> {
          let reply =
            codec.encode_reply(socket_info.codec)(
              join_ref,
              ref,
              topic_name,
              codec.StatusError,
              json.object([#("reason", json.string("rate_limited"))]),
            )
          let _send_result =
            send_frame_logged(state, socket_info, topic_name, reply)
          Nil
        }
        Error(Nil) -> Nil
      }
      emit_join_stop(state, started_at, telemetry.JoinRateLimited)
      actor.continue(state)
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
  state: State,
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Join ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "socket_not_found"),
      ])
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
      actor.continue(state)
    }
    Ok(socket_info) -> {
      case can_join_topic(socket_info, topic_name, state.config) {
        False ->
          reject_join_cap(
            state,
            socket_info,
            topic_name,
            join_ref,
            ref,
            started_at,
          )
        True ->
          replace_existing_then_join(
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
  }
}

/// Phoenix duplicate-join semantics: a `phx_join` for an already-joined
/// topic replaces the previous channel instance. Terminate the old instance
/// first (running its `terminate` callback and emitting `phx_close`) so
/// cleanup keyed off termination — presence untracking, bridge shutdown —
/// is never silently skipped by a rejoin.
fn replace_existing_then_join(
  state: State,
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State, Message) {
  let state = terminate_channel(state, socket_id, topic_name, channel.Normal)
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
      actor.continue(state)
    }
    Ok(socket_info) ->
      handle_join_with_handler(
        state,
        socket_info,
        socket_id,
        topic_name,
        payload,
        join_ref,
        ref,
        started_at,
      )
  }
}

fn can_join_topic(
  socket_info: SocketInfo,
  topic_name: String,
  config: CoordinatorConfig,
) -> Bool {
  config.max_joined_topics_per_socket <= 0
  || set.contains(socket_info.subscribed_topics, topic_name)
  || list.length(set.to_list(socket_info.subscribed_topics))
  < config.max_joined_topics_per_socket
}

fn reject_join_cap(
  state: State,
  socket_info: SocketInfo,
  topic_name: String,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  logger
  |> log.warn("Join rejected: topic cap exceeded", [
    #("socket_id", socket_info.id),
    #("topic", topic_name),
  ])
  let reply =
    codec.encode_reply(socket_info.codec)(
      join_ref,
      ref,
      topic_name,
      codec.StatusError,
      json.object([#("reason", json.string("too_many_topics"))]),
    )
  let _send_result = send_frame_logged(state, socket_info, topic_name, reply)
  emit_join_stop(state, started_at, telemetry.JoinTopicLimit)
  actor.continue(state)
}

fn handle_join_with_handler(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State, Message) {
  case find_handler(state.handlers, topic_name) {
    None -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Join handler missing", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("ref", optional_string(ref)),
        #("join_ref", optional_string(join_ref)),
      ])
      let reply =
        codec.encode_reply(socket_info.codec)(
          join_ref,
          ref,
          topic_name,
          codec.StatusError,
          json.object([#("reason", json.string("no_channel_handler"))]),
        )
      let _send_result =
        send_frame_logged(state, socket_info, topic_name, reply)
      emit_join_stop(state, started_at, telemetry.JoinNoHandler)
      actor.continue(state)
    }
    Some(handler) ->
      dispatch_join(
        state,
        socket_info,
        handler,
        socket_id,
        topic_name,
        payload,
        join_ref,
        ref,
        started_at,
      )
  }
}

fn handle_leave(
  state: State,
  socket_id: String,
  topic_name: String,
  msg_join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State, Message) {
  // A leave carrying a join_ref from a previous channel instance (the
  // client rejoined since sending it) must not close the new instance.
  let stale = case dict.get(state.sockets, socket_id) {
    Ok(socket_info) -> is_stale_join_ref(socket_info, topic_name, msg_join_ref)
    Error(Nil) -> False
  }
  use <- bool.lazy_guard(when: stale, return: fn() {
    coordinator_logger(state)
    |> log.debug("Leave dropped: stale join_ref", [
      #("socket_id", socket_id),
      #("topic", topic_name),
    ])
    actor.continue(state)
  })

  // Acknowledge the leave before terminating, so the client sees the reply
  // to its own ref first and the `phx_close` emitted by termination second —
  // matching the frame order Phoenix produces.
  case ref, dict.get(state.sockets, socket_id) {
    Some(r), Ok(socket_info) -> {
      let reply =
        codec.encode_reply(socket_info.codec)(
          joined_ref(socket_info, topic_name),
          Some(r),
          topic_name,
          codec.StatusOk,
          json.object([]),
        )
      let _send_result =
        send_frame_logged(state, socket_info, topic_name, reply)
      Nil
    }
    _, _ -> Nil
  }

  actor.continue(terminate_channel(state, socket_id, topic_name, channel.Normal))
}

/// A message is stale when it carries a join_ref from a previous channel
/// instance on this topic (the client rejoined since sending it). Messages
/// without a join_ref are never treated as stale.
fn is_stale_join_ref(
  socket_info: SocketInfo,
  topic_name: String,
  msg_join_ref: Option(String),
) -> Bool {
  case msg_join_ref, joined_ref(socket_info, topic_name) {
    Some(sent), Some(current) -> sent != current
    _, _ -> False
  }
}

fn handle_in(
  state: State,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  msg_join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State, Message) {
  // Check per-socket message rate limit
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed {
    False -> {
      let logger = coordinator_logger(state)
      logger
      |> log.warn("Message rate limited", [
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
      actor.continue(state)
    }
    True -> {
      handle_in_subscribed(
        state,
        socket_id,
        topic_name,
        event,
        payload,
        msg_join_ref,
        ref,
        started_at,
        kind,
      )
    }
  }
}

fn handle_in_subscribed(
  state: State,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  msg_join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Inbound message ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("reason", "socket_not_found"),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    Ok(socket_info) -> {
      case set.contains(socket_info.subscribed_topics, topic_name) {
        False ->
          reject_unjoined_event(
            state,
            socket_info,
            socket_id,
            topic_name,
            event,
            ref,
            started_at,
            kind,
          )
        True ->
          handle_in_current_instance(
            state,
            socket_info,
            socket_id,
            topic_name,
            event,
            payload,
            msg_join_ref,
            ref,
            started_at,
            kind,
          )
      }
    }
  }
}

/// Drop messages sent to a previous channel instance (stale join_ref after a
/// rejoin), matching Phoenix; otherwise continue to per-channel rate limits.
fn handle_in_current_instance(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  msg_join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State, Message) {
  case is_stale_join_ref(socket_info, topic_name, msg_join_ref) {
    True -> {
      coordinator_logger(state)
      |> log.debug("Inbound message dropped: stale join_ref", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageStale,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    False ->
      handle_in_rate_limited(
        state,
        socket_info,
        socket_id,
        topic_name,
        event,
        payload,
        ref,
        started_at,
        kind,
      )
  }
}

/// Reject an event pushed to a topic the socket has not joined. Phoenix
/// replies with `{"status":"error","response":{"reason":"unmatched topic"}}`
/// so the client's push errors immediately instead of timing out; messages
/// without a ref have nothing to correlate a reply with and are dropped.
fn reject_unjoined_event(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  event: String,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State, Message) {
  coordinator_logger(state)
  |> log.debug("Inbound message rejected", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("event", event),
    #("reason", "topic_not_joined"),
  ])
  case ref {
    Some(r) -> {
      let reply =
        codec.encode_reply(socket_info.codec)(
          None,
          Some(r),
          topic_name,
          codec.StatusError,
          json.object([#("reason", json.string("unmatched topic"))]),
        )
      let _send_result =
        send_frame_logged(state, socket_info, topic_name, reply)
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
  actor.continue(state)
}

fn handle_in_rate_limited(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State, Message) {
  let #(state, allowed) = check_channel_rate(state, socket_id, topic_name)
  case allowed {
    False -> {
      let logger = coordinator_logger(state)
      logger
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
      actor.continue(state)
    }
    True ->
      route_in_to_handler(
        state,
        socket_info,
        socket_id,
        topic_name,
        event,
        payload,
        ref,
        started_at,
        kind,
      )
  }
}

fn handle_info(
  state: State,
  socket_id: String,
  topic_name: String,
  channel_id: Int,
  info_message: Dynamic,
) -> actor.Next(State, Message) {
  let started_at = telemetry_start(state)
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Handle info ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "socket_not_found"),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    Ok(socket_info) -> {
      case set.contains(socket_info.subscribed_topics, topic_name) {
        False -> {
          let logger = coordinator_logger(state)
          logger
          |> log.debug("Handle info ignored", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("reason", "topic_not_joined"),
          ])
          emit_message_stop(
            state,
            started_at,
            telemetry.InfoMessage,
            telemetry.MessageUnjoined,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
        True ->
          route_info_to_registered_handler(
            state,
            socket_info,
            socket_id,
            topic_name,
            channel_id,
            info_message,
            started_at,
          )
      }
    }
  }
}

/// Handle incoming binary frames.
/// Routes to all subscribed topics for the socket.
fn handle_binary_in(
  state: State,
  socket_id: String,
  data: BitArray,
) -> actor.Next(State, Message) {
  // Decode with the connection's negotiated codec when known, so binary
  // frames are interpreted in the serializer the client actually used.
  let active_codec = case dict.get(state.sockets, socket_id) {
    Ok(socket_info) -> socket_info.codec
    Error(Nil) -> state.config.codec
  }
  case codec.decode_binary(active_codec) {
    Some(decode_binary) ->
      handle_route_binary_frame(state, socket_id, data, decode_binary)
    None -> handle_raw_binary_with_rate_limit(state, socket_id, data)
  }
}

fn handle_raw_binary_with_rate_limit(
  state: State,
  socket_id: String,
  data: BitArray,
) -> actor.Next(State, Message) {
  let started_at = telemetry_start(state)
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed {
    False -> {
      let logger = coordinator_logger(state)
      logger
      |> log.warn("Binary message rate limited", [#("socket_id", socket_id)])
      emit_message_stop(
        state,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageRateLimited,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    True -> handle_raw_binary_in_inner(state, socket_id, data, started_at)
  }
}

fn handle_route_binary_frame(
  state: State,
  socket_id: String,
  data: BitArray,
  decode_binary: fn(BitArray) -> Result(codec.Inbound, codec.DecodeError),
) -> actor.Next(State, Message) {
  case decode_binary(data) {
    Error(err) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.warn("Failed to decode binary wire protocol message", [
        #("socket_id", socket_id),
        #("error", codec.format_decode_error(err)),
      ])
      actor.continue(state)
    }
    Ok(msg) -> dispatch_inbound(state, socket_id, msg, telemetry.BinaryMessage)
  }
}

fn handle_raw_binary_in_inner(
  state: State,
  socket_id: String,
  data: BitArray,
  started_at: Int,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
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
      actor.continue(state)
    }
    Ok(socket_info) -> {
      use <- bool.lazy_guard(
        when: set.is_empty(socket_info.subscribed_topics),
        return: fn() {
          emit_message_stop(
            state,
            started_at,
            telemetry.BinaryMessage,
            telemetry.MessageUnjoined,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        },
      )
      let state =
        set.fold(socket_info.subscribed_topics, state, fn(st, topic_name) {
          route_binary_to_handler(
            st,
            socket_info,
            socket_id,
            topic_name,
            data,
            started_at,
          )
        })
      actor.continue(state)
    }
  }
}

fn handle_heartbeat(
  state: State,
  socket_id: String,
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      emit_message_stop(
        state,
        started_at,
        telemetry.HeartbeatMessage,
        telemetry.MessageSocketMissing,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    Ok(socket_info) -> {
      let updated_socket =
        SocketInfo(..socket_info, last_heartbeat: monotonic_time_ms())
      let new_sockets = dict.insert(state.sockets, socket_id, updated_socket)

      let reply = codec.encode_heartbeat_reply(socket_info.codec)(ref)
      let _send_result =
        send_frame_logged(state, socket_info, "__heartbeat__", reply)
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Heartbeat handled", [
        #("socket_id", socket_id),
        #("ref", optional_string(ref)),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.HeartbeatMessage,
        telemetry.MessageHandled,
        telemetry.NotApplicable,
      )
      actor.continue(State(..state, sockets: new_sockets))
    }
  }
}

/// Check all sockets for heartbeat timeout and evict stale ones
fn handle_check_heartbeats(state: State) -> actor.Next(State, Message) {
  let now = monotonic_time_ms()
  let timeout_ms = state.config.heartbeat_timeout_ms

  let stale_socket_ids =
    dict.fold(state.sockets, [], fn(acc, socket_id, socket_info) {
      let elapsed = now - socket_info.last_heartbeat
      case elapsed > timeout_ms {
        True -> [socket_id, ..acc]
        False -> acc
      }
    })

  let logger = coordinator_logger(state)
  list.each(stale_socket_ids, fn(socket_id) {
    logger
    |> log.warn("Evicting socket due to heartbeat timeout", [
      #("socket_id", socket_id),
      #("timeout_ms", int.to_string(timeout_ms)),
    ])
  })

  let state =
    list.fold(stale_socket_ids, state, fn(st, socket_id) {
      disconnect_socket(st, socket_id, channel.HeartbeatTimeout)
    })

  case state.self_subject {
    Some(subject) -> schedule_heartbeat_check(subject, state.config)
    None -> Nil
  }

  actor.continue(state)
}

/// Disconnect a socket, running terminate on all its channels.
/// Shared logic used by both SocketDisconnected and CheckHeartbeats.
fn disconnect_socket(
  state: State,
  socket_id: String,
  reason: StopReason,
) -> State {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket_info) -> {
      let state = remove_socket_rate_limits(state, socket_id)
      let logger = coordinator_logger(state)
      logger
      |> log.debug(
        "Socket disconnected",
        list.append(
          [
            #("socket_id", socket_id),
            #("reason", stop_reason(reason)),
          ],
          joined_topics_metadata(socket_info),
        ),
      )
      let state =
        set.fold(socket_info.subscribed_topics, state, fn(st, topic_name) {
          terminate_channel(st, socket_id, topic_name, reason)
        })

      let new_topics =
        dict.map_values(state.topics, fn(_topic, subscribers) {
          set.delete(subscribers, socket_id)
        })

      let new_sockets = dict.delete(state.sockets, socket_id)

      // Actively close the transport connection after the terminal frames
      // above have been queued. Without this, evicted sockets stay open as
      // zombies: the client believes it is connected while every frame it
      // sends (including rejoins) is dropped, and per-IP connection slots
      // remain held. A no-op when the transport already closed (Normal
      // disconnects) or never registered a closer.
      socket_info.close()

      let new_state = State(..state, sockets: new_sockets, topics: new_topics)
      use <- bool.guard(when: !state.config.telemetry, return: new_state)
      telemetry.emit(
        True,
        telemetry.SocketDisconnected(
          duration: telemetry.duration_since(socket_info.connected_at),
          joined_channels: set.size(socket_info.subscribed_topics),
          reason: disconnect_reason_telemetry(reason),
        ),
      )
      new_state
    }
  }
}

fn handle_broadcast(
  state: State,
  topic_name: String,
  event: String,
  payload: json.Json,
  except: Option(String),
  origin: telemetry.BroadcastOrigin,
) -> actor.Next(State, Message) {
  let started_at = telemetry_start(state)
  let subscribers =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
    |> set.to_list()

  let recipients = case except {
    None -> subscribers
    Some(except_id) -> list.filter(subscribers, fn(id) { id != except_id })
  }

  let logger = coordinator_logger(state)
  logger
  |> log.debug("Broadcast dispatched", [
    #("topic", topic_name),
    #("event", event),
    #("recipient_count", int.to_string(list.length(recipients))),
    #("except", optional_string(except)),
  ])
  let #(recipient_count, send_failures) =
    list.fold(recipients, #(0, 0), fn(counts, socket_id) {
      case dict.get(state.sockets, socket_id) {
        Ok(socket_info) -> {
          // Encode per recipient so connections negotiating different
          // serializers each receive a frame in their own wire format.
          let msg =
            codec.encode_push(socket_info.codec)(topic_name, event, payload)
          let send_result =
            send_frame_logged(state, socket_info, topic_name, msg)
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

  use <- bool.lazy_guard(when: state.config.telemetry, return: fn() {
    telemetry.emit(
      True,
      telemetry.BroadcastStop(
        duration: telemetry.duration_since(started_at),
        recipients: recipient_count,
        send_failures: send_failures,
        origin: origin,
      ),
    )
    actor.continue(state)
  })
  actor.continue(state)
}

fn handle_remote_broadcast(
  state: State,
  pubsub_msg: pubsub.Message(json.Json),
) -> actor.Next(State, Message) {
  let except = case pubsub_msg.from {
    pubsub.FromSocket(_, socket_id) -> Some(socket_id)
    pubsub.System | pubsub.FromPid(_) -> None
  }

  handle_broadcast(
    state,
    pubsub_msg.topic,
    pubsub_msg.event,
    pubsub_msg.payload,
    except,
    telemetry.Remote,
  )
}

/// Find the first handler that matches the topic
fn find_handler(
  handlers: List(ChannelHandler),
  topic_name: String,
) -> Option(ChannelHandler) {
  list.find(handlers, fn(h) { topic.matches(h.pattern, topic_name) })
  |> option.from_result()
}

/// Terminate a channel subscription
fn terminate_channel(
  state: State,
  socket_id: String,
  topic_name: String,
  reason: StopReason,
) -> State {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket_info) -> {
      case set.contains(socket_info.subscribed_topics, topic_name) {
        False -> state
        True ->
          do_terminate_channel(
            state,
            socket_info,
            socket_id,
            topic_name,
            reason,
          )
      }
    }
  }
}

/// Store the next channel instance for a socket/topic
fn update_instance(
  state: State,
  socket_id: String,
  topic_name: String,
  instance: JoinedChannel,
) -> State {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket_info) -> {
      let new_instances =
        dict.insert(socket_info.channel_instances, topic_name, instance)
      let new_socket_info =
        SocketInfo(..socket_info, channel_instances: new_instances)
      let new_sockets = dict.insert(state.sockets, socket_id, new_socket_info)
      State(..state, sockets: new_sockets)
    }
  }
}

/// Route raw inbound text from a transport to the coordinator.
///
/// Frames that fail to decode are logged and dropped.
pub fn route_message(
  coord: Subject(Message),
  socket_id: String,
  raw_text: String,
) -> Nil {
  process.send(coord, RouteText(socket_id, raw_text))
}

/// Route a transport-decoded inbound message to the coordinator.
pub fn route_decoded(
  coord: Subject(Message),
  socket_id: String,
  msg: codec.Inbound,
) -> Nil {
  process.send(coord, RouteDecoded(socket_id, msg))
}

/// Route a transport-decoded binary message to the coordinator while
/// preserving its frame kind for channel-message telemetry.
pub fn route_decoded_binary(
  coord: Subject(Message),
  socket_id: String,
  msg: codec.Inbound,
) -> Nil {
  process.send(coord, RouteDecodedBinary(socket_id, msg))
}

fn handle_route_text(
  state: State,
  socket_id: String,
  raw_text: String,
) -> actor.Next(State, Message) {
  let active_codec = case dict.get(state.sockets, socket_id) {
    Ok(socket_info) -> socket_info.codec
    Error(Nil) -> state.config.codec
  }
  let logging = internal_logging(state.config.logging)
  case codec.decode_text(active_codec)(raw_text) {
    Error(err) -> {
      let logger = coordinator_logger(state)
      logger
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
      actor.continue(state)
    }
    Ok(msg) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug(
        "Inbound text frame decoded",
        list.append(
          [
            #("socket_id", socket_id),
            #("topic", topic.sanitize_for_log(codec.inbound_topic(msg))),
            #(
              "event",
              topic.sanitize_for_log(inbound_kind(codec.inbound_kind(msg))),
            ),
            #("ref", optional_string(codec.inbound_ref(msg))),
            #("join_ref", optional_string(codec.inbound_join_ref(msg))),
          ],
          internal.preview_metadata("frame_preview", raw_text, logging),
        ),
      )
      dispatch_inbound(state, socket_id, msg, telemetry.TextMessage)
    }
  }
}

fn dispatch_inbound(
  state: State,
  socket_id: String,
  msg: codec.Inbound,
  message_kind: telemetry.MessageKind,
) -> actor.Next(State, Message) {
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
      use state <- with_message_rate_limit(state, socket_id, "leave")
      case is_valid_topic(msg_topic, state.config) {
        False -> {
          let safe_topic = topic.sanitize_for_log(msg_topic)
          coordinator_logger(state)
          |> log.warn("Leave dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", safe_topic),
          ])
          actor.continue(state)
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
      let #(state, allowed) = check_message_rate(state, socket_id)
      case allowed {
        False -> {
          coordinator_logger(state)
          |> log.warn("Message rate limited", [
            #("socket_id", socket_id),
            #("kind", "heartbeat"),
          ])
          emit_message_stop(
            state,
            started_at,
            telemetry.HeartbeatMessage,
            telemetry.MessageRateLimited,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
        True -> handle_heartbeat(state, socket_id, msg_ref, started_at)
      }
    }
    codec.Event(event) -> {
      let started_at = telemetry_start(state)
      let resolved = resolve_event_topic(state, socket_id, msg_topic)
      case
        is_valid_topic(resolved, state.config),
        is_valid_event(event, state.config)
      {
        True, True ->
          handle_in(
            state,
            socket_id,
            resolved,
            event,
            codec.inbound_payload(msg),
            codec.inbound_join_ref(msg),
            msg_ref,
            started_at,
            message_kind,
          )
        False, _ -> {
          let safe_topic = topic.sanitize_for_log(msg_topic)
          let safe_event = topic.sanitize_for_log(event)
          coordinator_logger(state)
          |> log.warn("Event dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", safe_topic),
            #("event", safe_event),
          ])
          emit_message_stop(
            state,
            started_at,
            message_kind,
            telemetry.MessageInvalid,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
        True, False -> {
          let safe_event = topic.sanitize_for_log(event)
          coordinator_logger(state)
          |> log.warn("Event dropped: invalid event", [
            #("socket_id", socket_id),
            #("topic", msg_topic),
            #("event", safe_event),
          ])
          emit_message_stop(
            state,
            started_at,
            message_kind,
            telemetry.MessageInvalid,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
      }
    }
  }
}

/// Resolve the topic for an inbound Event. Codecs that opt in via
/// `codec.with_topicless_events` (e.g. Socket.IO-style framings) omit a
/// per-frame topic; for those, an empty topic routes to the socket's single
/// joined topic. With zero or multiple joined topics — or for
/// topic-carrying codecs like Phoenix, where an empty topic is a protocol
/// violation — the original (empty) topic is returned so validation drops it.
fn resolve_event_topic(
  state: State,
  socket_id: String,
  requested: String,
) -> String {
  case requested {
    "" ->
      case dict.get(state.sockets, socket_id) {
        Ok(info) ->
          case
            codec.topicless_events(info.codec),
            set.to_list(info.subscribed_topics)
          {
            True, [only] -> only
            _, _ -> requested
          }
        Error(Nil) -> requested
      }
    _ -> requested
  }
}

fn is_valid_topic(topic_name: String, config: CoordinatorConfig) -> Bool {
  string.byte_size(topic_name) <= config.max_topic_length
  && result.is_ok(topic.validate(topic_name))
}

/// Topics under the `beryl:` prefix are reserved for internal machinery
/// (e.g. the presence replication sync topic). Clients must not join them:
/// with a catch-all handler registered, a client join would subscribe the
/// coordinator to the internal topic and forward its traffic — including
/// other users' presence state — to that client.
fn is_reserved_topic(topic_name: String) -> Bool {
  string.starts_with(topic_name, "beryl:")
}

/// Event names under the `phx_` prefix are reserved by the protocol.
/// Client-supplied `phx_*` events (e.g. a forged `phx_reply`) must never
/// reach channel handlers, where a naive echo channel could re-broadcast
/// frames that confuse other clients.
fn is_valid_event(event_name: String, config: CoordinatorConfig) -> Bool {
  string.byte_size(event_name) <= config.max_event_length
  && !string.starts_with(event_name, "phx_")
  && result.is_ok(topic.validate_event(event_name))
}

/// Apply the per-socket message limiter to protocol frames (heartbeat,
/// leave) so flooding them cannot bypass `with_message_rate` — each
/// heartbeat otherwise generates an amplified reply exempt from limits.
fn with_message_rate_limit(
  state: State,
  socket_id: String,
  kind: String,
  next: fn(State) -> actor.Next(State, Message),
) -> actor.Next(State, Message) {
  let #(state, allowed) = check_message_rate(state, socket_id)
  case allowed {
    False -> {
      coordinator_logger(state)
      |> log.warn("Message rate limited", [
        #("socket_id", socket_id),
        #("kind", kind),
      ])
      actor.continue(state)
    }
    True -> next(state)
  }
}

/// Send a `phx_reply` error for a join with an invalid topic and drop the message.
fn reject_invalid_join(
  state: State,
  socket_id: String,
  msg: codec.Inbound,
  started_at: Int,
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  let safe_topic = topic.sanitize_for_log(codec.inbound_topic(msg))
  logger
  |> log.warn("Join rejected: invalid topic", [
    #("socket_id", socket_id),
    #("topic", safe_topic),
  ])
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      emit_join_stop(state, started_at, telemetry.JoinSocketMissing)
      actor.continue(state)
    }
    Ok(socket_info) -> {
      let reply =
        codec.encode_reply(socket_info.codec)(
          codec.inbound_join_ref(msg),
          codec.inbound_ref(msg),
          codec.inbound_topic(msg),
          codec.StatusError,
          json.object([#("reason", json.string("invalid_topic"))]),
        )
      let _send_result =
        send_frame_logged(state, socket_info, safe_topic, reply)
      emit_join_stop(state, started_at, telemetry.JoinInvalidTopic)
      actor.continue(state)
    }
  }
}

/// Route a binary WebSocket frame to the coordinator.
///
/// Binary frames are decoded by the configured codec when it has a binary
/// decoder; otherwise they are dispatched raw to all subscribed topics for
/// the socket.
pub fn route_binary(
  coord: Subject(Message),
  socket_id: String,
  data: BitArray,
) -> Nil {
  process.send(coord, HandleBinary(socket_id, data))
}

fn dispatch_join(
  state: State,
  socket_info: SocketInfo,
  handler: ChannelHandler,
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
  started_at: Int,
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  logger
  |> log.debug("Join handler matched", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("ref", optional_string(ref)),
    #("join_ref", optional_string(join_ref)),
  ])
  let ctx =
    SocketContext(
      socket_id: socket_id,
      topic: topic_name,
      send: socket_info.send,
      send_binary: socket_info.send_binary,
      close: socket_info.close,
    )

  case
    internal.rescue(fn() {
      handler.join(topic_name, payload, socket_info.connect_assigns, ctx)
    })
  {
    Error(crash) ->
      reject_crashed_join(
        state,
        socket_info,
        topic_name,
        join_ref,
        ref,
        crash,
        started_at,
      )
    Ok(JoinErrorErased(reason)) -> {
      logger
      |> log.debug("Join rejected", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("ref", optional_string(ref)),
        #("join_ref", optional_string(join_ref)),
      ])
      let reply =
        codec.encode_reply(socket_info.codec)(
          join_ref,
          ref,
          topic_name,
          codec.StatusError,
          reason,
        )
      let _send_result =
        send_frame_logged(state, socket_info, topic_name, reply)
      emit_join_stop(state, started_at, telemetry.JoinHandlerRejected)
      actor.continue(state)
    }
    Ok(JoinOkErased(reply_payload, instance)) -> {
      logger
      |> log.debug("Join accepted", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("ref", optional_string(ref)),
        #("join_ref", optional_string(join_ref)),
      ])
      let new_subscribed = set.insert(socket_info.subscribed_topics, topic_name)
      let new_instances =
        dict.insert(socket_info.channel_instances, topic_name, instance)
      let new_channel_ids =
        dict.insert(socket_info.channel_ids, topic_name, handler.id)
      let new_join_refs =
        dict.insert(socket_info.join_refs, topic_name, join_ref)
      let new_socket_info =
        SocketInfo(
          ..socket_info,
          subscribed_topics: new_subscribed,
          channel_instances: new_instances,
          channel_ids: new_channel_ids,
          join_refs: new_join_refs,
        )

      let existing_topic_subscribers =
        dict.get(state.topics, topic_name)
        |> result.unwrap(set.new())
      let topic_subscribers =
        existing_topic_subscribers
        |> set.insert(socket_id)

      case state.pubsub, set.is_empty(existing_topic_subscribers) {
        Some(ps), True -> pubsub.subscribe(ps, topic_name)
        _, _ -> Nil
      }

      let new_topics = dict.insert(state.topics, topic_name, topic_subscribers)
      let new_sockets = dict.insert(state.sockets, socket_id, new_socket_info)

      let response = case reply_payload {
        None -> json.object([])
        Some(p) -> p
      }
      let reply =
        codec.encode_reply(socket_info.codec)(
          join_ref,
          ref,
          topic_name,
          codec.StatusOk,
          response,
        )
      let _send_result =
        send_frame_logged(state, socket_info, topic_name, reply)

      emit_join_stop(state, started_at, telemetry.JoinAccepted)
      actor.continue(State(..state, sockets: new_sockets, topics: new_topics))
    }
  }
}

/// Reject a join whose channel callback crashed. No subscription state has
/// been created yet, so the socket keeps working; the client receives an
/// error reply mirroring Phoenix's "join crashed" response.
fn reject_crashed_join(
  state: State,
  socket_info: SocketInfo,
  topic_name: String,
  join_ref: Option(String),
  ref: Option(String),
  crash: String,
  started_at: Int,
) -> actor.Next(State, Message) {
  coordinator_logger(state)
  |> log.error("Channel join crashed", [
    #("socket_id", socket_info.id),
    #("topic", topic_name),
    #("crash", crash),
  ])
  let reply =
    codec.encode_reply(socket_info.codec)(
      join_ref,
      ref,
      topic_name,
      codec.StatusError,
      json.object([#("reason", json.string("join crashed"))]),
    )
  let _send_result = send_frame_logged(state, socket_info, topic_name, reply)
  emit_join_stop(state, started_at, telemetry.JoinCallbackFailed)
  actor.continue(state)
}

/// Tear down a channel whose callback crashed, leaving the socket and the
/// coordinator's other channels untouched.
fn handle_callback_crash(
  state: State,
  socket_id: String,
  topic_name: String,
  callback_name: String,
  crash: String,
) -> State {
  coordinator_logger(state)
  |> log.error("Channel callback crashed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("callback", callback_name),
    #("crash", crash),
  ])
  terminate_channel(state, socket_id, topic_name, channel.Errored(crash))
}

fn dispatch_handle_in(
  state: State,
  socket_info: SocketInfo,
  instance: JoinedChannel,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  logger
  |> log.debug("Inbound message routed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("event", event),
    #("ref", optional_string(ref)),
  ])
  let ctx =
    SocketContext(
      socket_id: socket_id,
      topic: topic_name,
      send: socket_info.send,
      send_binary: socket_info.send_binary,
      close: socket_info.close,
    )

  case internal.rescue(fn() { instance.handle_in(event, payload, ctx) }) {
    Error(crash) -> {
      let state =
        handle_callback_crash(state, socket_id, topic_name, "handle_in", crash)
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageCallbackFailed,
        telemetry.CallbackFailed,
      )
      actor.continue(state)
    }
    Ok(NoReplyErased(next_instance)) -> {
      logger
      |> log.debug("Channel callback returned no reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
      ])
      let state = update_instance(state, socket_id, topic_name, next_instance)
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageHandled,
        telemetry.NoReply,
      )
      actor.continue(state)
    }

    Ok(ReplyErased(_reply_event, reply_payload, next_instance)) -> {
      logger
      |> log.debug("Channel callback returned reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("ref", optional_string(ref)),
      ])
      case ref {
        Some(r) -> {
          let reply =
            codec.encode_reply(socket_info.codec)(
              joined_ref(socket_info, topic_name),
              Some(r),
              topic_name,
              codec.StatusOk,
              reply_payload,
            )
          let _send_result =
            send_frame_logged(state, socket_info, topic_name, reply)
          Nil
        }
        None -> Nil
      }
      let state = update_instance(state, socket_id, topic_name, next_instance)
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageHandled,
        telemetry.Reply,
      )
      actor.continue(state)
    }

    Ok(ReplyErrorErased(reply_payload, next_instance)) -> {
      logger
      |> log.debug("Channel callback returned error reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("ref", optional_string(ref)),
      ])
      case ref {
        Some(r) -> {
          let reply =
            codec.encode_reply(socket_info.codec)(
              joined_ref(socket_info, topic_name),
              Some(r),
              topic_name,
              codec.StatusError,
              reply_payload,
            )
          let _send_result =
            send_frame_logged(state, socket_info, topic_name, reply)
          Nil
        }
        None -> Nil
      }
      let state = update_instance(state, socket_id, topic_name, next_instance)
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageHandled,
        telemetry.ReplyError,
      )
      actor.continue(state)
    }

    Ok(PushErased(push_event, push_payload, next_instance)) -> {
      logger
      |> log.debug("Channel callback returned push", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("push_event", push_event),
      ])
      let msg =
        codec.encode_push(socket_info.codec)(
          topic_name,
          push_event,
          push_payload,
        )
      let _send_result = send_frame_logged(state, socket_info, topic_name, msg)
      let state = update_instance(state, socket_id, topic_name, next_instance)
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageHandled,
        telemetry.Push,
      )
      actor.continue(state)
    }

    Ok(StopErased(reason)) -> {
      logger
      |> log.debug("Channel callback stopped channel", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("reason", stop_reason(reason)),
      ])
      let state = terminate_channel(state, socket_id, topic_name, reason)
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageHandled,
        telemetry.Stop,
      )
      actor.continue(state)
    }
  }
}

fn dispatch_handle_info(
  state: State,
  socket_info: SocketInfo,
  instance: JoinedChannel,
  socket_id: String,
  topic_name: String,
  info_message: Dynamic,
  started_at: Int,
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  logger
  |> log.debug("Handle info routed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
  ])
  let ctx =
    SocketContext(
      socket_id: socket_id,
      topic: topic_name,
      send: socket_info.send,
      send_binary: socket_info.send_binary,
      close: socket_info.close,
    )

  case internal.rescue(fn() { instance.handle_info(info_message, ctx) }) {
    Error(crash) -> {
      let state =
        handle_callback_crash(
          state,
          socket_id,
          topic_name,
          "handle_info",
          crash,
        )
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageCallbackFailed,
        telemetry.CallbackFailed,
      )
      actor.continue(state)
    }
    Ok(NoReplyErased(next_instance)) -> {
      logger
      |> log.debug("Channel callback returned no reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_info"),
      ])
      let state = update_instance(state, socket_id, topic_name, next_instance)
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageHandled,
        telemetry.NoReply,
      )
      actor.continue(state)
    }

    Ok(ReplyErased(reply_event, reply_payload, next_instance)) -> {
      logger
      |> log.debug("Channel callback returned push", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_info"),
        #("push_event", reply_event),
      ])
      // No ref correlation in handle_info, so reply and push are
      // wire-identical: both become a server-initiated push.
      let msg =
        codec.encode_push(socket_info.codec)(
          topic_name,
          reply_event,
          reply_payload,
        )
      let _send_result = send_frame_logged(state, socket_info, topic_name, msg)
      let state = update_instance(state, socket_id, topic_name, next_instance)
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageHandled,
        telemetry.Reply,
      )
      actor.continue(state)
    }

    Ok(PushErased(reply_event, reply_payload, next_instance)) -> {
      logger
      |> log.debug("Channel callback returned push", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_info"),
        #("push_event", reply_event),
      ])
      let msg =
        codec.encode_push(socket_info.codec)(
          topic_name,
          reply_event,
          reply_payload,
        )
      let _send_result = send_frame_logged(state, socket_info, topic_name, msg)
      let state = update_instance(state, socket_id, topic_name, next_instance)
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageHandled,
        telemetry.Push,
      )
      actor.continue(state)
    }

    Ok(ReplyErrorErased(_payload, next_instance)) -> {
      // Error replies require a client ref for correlation; handle_info is
      // server-originated so there is nothing to attach the error to.
      logger
      |> log.warn("Error reply dropped: no client ref in handle_info", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      let state = update_instance(state, socket_id, topic_name, next_instance)
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageHandled,
        telemetry.ReplyError,
      )
      actor.continue(state)
    }

    Ok(StopErased(reason)) -> {
      logger
      |> log.debug("Channel callback stopped channel", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_info"),
        #("reason", stop_reason(reason)),
      ])
      let state = terminate_channel(state, socket_id, topic_name, reason)
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageHandled,
        telemetry.Stop,
      )
      actor.continue(state)
    }
  }
}

fn dispatch_handle_binary(
  st: State,
  socket_info: SocketInfo,
  instance: JoinedChannel,
  socket_id: String,
  topic_name: String,
  data: BitArray,
  started_at: Int,
) -> State {
  let logger = coordinator_logger(st)
  logger
  |> log.debug("Binary message routed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
  ])
  let ctx =
    SocketContext(
      socket_id: socket_id,
      topic: topic_name,
      send: socket_info.send,
      send_binary: socket_info.send_binary,
      close: socket_info.close,
    )

  case internal.rescue(fn() { instance.handle_binary(data, ctx) }) {
    Error(crash) -> {
      let st =
        handle_callback_crash(st, socket_id, topic_name, "handle_binary", crash)
      emit_message_stop(
        st,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageCallbackFailed,
        telemetry.CallbackFailed,
      )
      st
    }
    Ok(NoReplyErased(next_instance)) -> {
      logger
      |> log.debug("Channel callback returned no reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_binary"),
      ])
      let st = update_instance(st, socket_id, topic_name, next_instance)
      emit_message_stop(
        st,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageHandled,
        telemetry.NoReply,
      )
      st
    }
    Ok(ReplyErased(reply_event, reply_payload, next_instance)) -> {
      logger
      |> log.debug("Channel callback returned reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_binary"),
      ])
      // Raw binary frames carry no ref to correlate a reply with, so the
      // reply is delivered as a push under the handler's own event name
      // (mirroring handle_info).
      let msg =
        codec.encode_push(socket_info.codec)(
          topic_name,
          reply_event,
          reply_payload,
        )
      let _send_result = send_frame_logged(st, socket_info, topic_name, msg)
      let st = update_instance(st, socket_id, topic_name, next_instance)
      emit_message_stop(
        st,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageHandled,
        telemetry.Reply,
      )
      st
    }
    Ok(ReplyErrorErased(_payload, next_instance)) -> {
      // Raw binary frames carry no ref to correlate an error reply with.
      logger
      |> log.warn("Error reply dropped: no client ref in handle_binary", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      let st = update_instance(st, socket_id, topic_name, next_instance)
      emit_message_stop(
        st,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageHandled,
        telemetry.ReplyError,
      )
      st
    }
    Ok(PushErased(push_event, push_payload, next_instance)) -> {
      logger
      |> log.debug("Channel callback returned push", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_binary"),
        #("push_event", push_event),
      ])
      let msg =
        codec.encode_push(socket_info.codec)(
          topic_name,
          push_event,
          push_payload,
        )
      let _send_result = send_frame_logged(st, socket_info, topic_name, msg)
      let st = update_instance(st, socket_id, topic_name, next_instance)
      emit_message_stop(
        st,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageHandled,
        telemetry.Push,
      )
      st
    }
    Ok(StopErased(reason)) -> {
      logger
      |> log.debug("Channel callback stopped channel", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_binary"),
        #("reason", stop_reason(reason)),
      ])
      let st = terminate_channel(st, socket_id, topic_name, reason)
      emit_message_stop(
        st,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageHandled,
        telemetry.Stop,
      )
      st
    }
  }
}

/// Notify the client that its channel instance ended. Phoenix clients rely
/// on `phx_close`/`phx_error` to leave the joined state (and, for errors,
/// schedule a rejoin) instead of waiting out push timeouts. Codecs without
/// close/error encoders skip the notification.
fn send_terminal_frame(
  state: State,
  socket_info: SocketInfo,
  topic_name: String,
  reason: StopReason,
) -> Nil {
  let encoder = case reason {
    channel.Errored(_) -> codec.encode_error(socket_info.codec)
    channel.Normal | channel.Shutdown | channel.HeartbeatTimeout ->
      codec.encode_close(socket_info.codec)
  }
  case encoder {
    Some(encode) -> {
      let _send_result =
        send_frame_logged(
          state,
          socket_info,
          topic_name,
          encode(joined_ref(socket_info, topic_name), topic_name),
        )
      Nil
    }
    None -> Nil
  }
}

/// The join_ref of the socket's current channel instance on a topic, if any.
fn joined_ref(socket_info: SocketInfo, topic_name: String) -> Option(String) {
  dict.get(socket_info.join_refs, topic_name)
  |> result.unwrap(None)
}

fn do_terminate_channel(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  reason: StopReason,
) -> State {
  case joined_instance(socket_info, topic_name) {
    Some(instance) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Channel terminated", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", stop_reason(reason)),
      ])
      let ctx =
        SocketContext(
          socket_id: socket_id,
          topic: topic_name,
          send: socket_info.send,
          send_binary: socket_info.send_binary,
          close: socket_info.close,
        )
      case internal.rescue(fn() { instance.terminate(reason, ctx) }) {
        Ok(Nil) -> Nil
        Error(crash) ->
          logger
          |> log.error("Channel terminate crashed", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("crash", crash),
          ])
      }
    }
    None -> Nil
  }

  send_terminal_frame(state, socket_info, topic_name, reason)

  let state = remove_channel_bucket(state, socket_id, topic_name)

  let new_subscribed = set.delete(socket_info.subscribed_topics, topic_name)
  let new_instances = dict.delete(socket_info.channel_instances, topic_name)
  let new_channel_ids = dict.delete(socket_info.channel_ids, topic_name)
  let new_join_refs = dict.delete(socket_info.join_refs, topic_name)
  let new_socket_info =
    SocketInfo(
      ..socket_info,
      subscribed_topics: new_subscribed,
      channel_instances: new_instances,
      channel_ids: new_channel_ids,
      join_refs: new_join_refs,
    )

  let topic_subscribers =
    dict.get(state.topics, topic_name)
    |> result.unwrap(set.new())
    |> set.delete(socket_id)
  let new_topics = case set.is_empty(topic_subscribers) {
    True -> {
      case state.pubsub {
        Some(ps) -> pubsub.unsubscribe(ps, topic_name)
        None -> Nil
      }
      dict.delete(state.topics, topic_name)
    }
    False -> dict.insert(state.topics, topic_name, topic_subscribers)
  }

  let new_sockets = dict.insert(state.sockets, socket_id, new_socket_info)

  State(..state, sockets: new_sockets, topics: new_topics)
}

fn route_in_to_handler(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
  started_at: Int,
  kind: telemetry.MessageKind,
) -> actor.Next(State, Message) {
  case joined_instance(socket_info, topic_name) {
    None -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Inbound message ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("reason", "handler_not_found"),
      ])
      emit_message_stop(
        state,
        started_at,
        kind,
        telemetry.MessageUnjoined,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    Some(instance) ->
      dispatch_handle_in(
        state,
        socket_info,
        instance,
        socket_id,
        topic_name,
        event,
        payload,
        ref,
        started_at,
        kind,
      )
  }
}

fn route_info_to_registered_handler(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  channel_id: Int,
  info_message: Dynamic,
  started_at: Int,
) -> actor.Next(State, Message) {
  // The id check is what makes the info erasure sound: the message was
  // erased from the info type of the RegisteredChannel with this id, and
  // the joined instance restoring it derives from the same registration.
  case dict.get(socket_info.channel_ids, topic_name) {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Handle info ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "channel_id_not_found"),
      ])
      emit_message_stop(
        state,
        started_at,
        telemetry.InfoMessage,
        telemetry.MessageUnjoined,
        telemetry.NotApplicable,
      )
      actor.continue(state)
    }
    Ok(joined_channel_id) -> {
      case
        joined_channel_id == channel_id,
        joined_instance(socket_info, topic_name)
      {
        True, Some(instance) ->
          dispatch_handle_info(
            state,
            socket_info,
            instance,
            socket_id,
            topic_name,
            info_message,
            started_at,
          )
        True, None -> {
          let logger = coordinator_logger(state)
          logger
          |> log.debug("Handle info ignored", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("reason", "channel_instance_not_found"),
          ])
          emit_message_stop(
            state,
            started_at,
            telemetry.InfoMessage,
            telemetry.MessageUnjoined,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
        False, _ -> {
          let logger = coordinator_logger(state)
          logger
          |> log.debug("Handle info ignored", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("reason", "registered_channel_mismatch"),
          ])
          emit_message_stop(
            state,
            started_at,
            telemetry.InfoMessage,
            telemetry.MessageStale,
            telemetry.NotApplicable,
          )
          actor.continue(state)
        }
      }
    }
  }
}

/// The joined channel instance for a socket/topic, if the topic is joined.
fn joined_instance(
  socket_info: SocketInfo,
  topic_name: String,
) -> Option(JoinedChannel) {
  dict.get(socket_info.channel_instances, topic_name)
  |> option.from_result()
}

fn route_binary_to_handler(
  st: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  data: BitArray,
  started_at: Int,
) -> State {
  case joined_instance(socket_info, topic_name) {
    None -> {
      let logger = coordinator_logger(st)
      logger
      |> log.debug("Binary message ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "handler_not_found"),
      ])
      emit_message_stop(
        st,
        started_at,
        telemetry.BinaryMessage,
        telemetry.MessageUnjoined,
        telemetry.NotApplicable,
      )
      st
    }
    Some(instance) ->
      dispatch_handle_binary(
        st,
        socket_info,
        instance,
        socket_id,
        topic_name,
        data,
        started_at,
      )
  }
}
