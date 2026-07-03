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
import beryl/rate_limit.{type RateLimiter}
import beryl/topic.{type TopicPattern}
import beryl/wire/codec.{type Codec}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// Type-erased channel handler for storage
/// The actual typed Channel is converted to this for the registry
pub type ChannelHandler {
  ChannelHandler(
    id: Int,
    pattern: TopicPattern,
    join: fn(String, Dynamic, SocketContext) -> JoinResultErased,
    handle_in: fn(String, Dynamic, SocketContext) -> HandleResultErased,
    handle_binary: fn(BitArray, SocketContext) -> HandleResultErased,
    terminate: fn(StopReason, SocketContext) -> Nil,
  )
}

/// Context passed to handlers (replaces Socket in erased form)
pub type SocketContext {
  SocketContext(
    socket_id: String,
    topic: String,
    /// Current assigns for this socket/topic (type-erased)
    assigns: Dynamic,
    /// Function to send text messages to this socket
    send: fn(String) -> Result(Nil, Nil),
    /// Function to send binary data to this socket
    send_binary: fn(BitArray) -> Result(Nil, Nil),
  )
}

/// Type-erased join result
pub type JoinResultErased {
  JoinOkErased(reply: Option(json.Json), assigns: Dynamic)
  JoinErrorErased(reason: json.Json)
}

/// Type-erased handle result
pub type HandleResultErased {
  NoReplyErased(assigns: Dynamic)
  ReplyErased(event: String, payload: json.Json, assigns: Dynamic)
  PushErased(event: String, payload: json.Json, assigns: Dynamic)
  StopErased(reason: StopReason)
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
    /// Per-socket message rate limiter (None = unlimited)
    message_limiter: Option(RateLimiter),
    /// Per-socket join rate limiter (None = unlimited)
    join_limiter: Option(RateLimiter),
    /// Per-channel message rate limiter (None = unlimited)
    channel_limiter: Option(RateLimiter),
    /// Maximum active channel-limiter keys per socket. Values <= 0 disable the cap.
    channel_limiter_max_keys_per_socket: Int,
    /// Maximum byte length for client-supplied topic strings (default: 256).
    /// Topics exceeding this limit are rejected before reaching a channel handler.
    max_topic_length: Int,
    /// Maximum byte length for client-supplied event name strings (default: 64).
    /// Events exceeding this limit are dropped before reaching a channel handler.
    max_event_length: Int,
    /// Maximum joined topics per socket. Values <= 0 disable the cap.
    max_joined_topics_per_socket: Int,
    /// Logging configuration for coordinator diagnostics.
    logging: LoggingConfig,
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
    message_limiter: None,
    join_limiter: None,
    channel_limiter: None,
    channel_limiter_max_keys_per_socket: 1000,
    max_topic_length: 256,
    max_event_length: 64,
    max_joined_topics_per_socket: 1000,
    logging: LoggingConfig(
      level: Info,
      include_payloads: False,
      payload_preview_bytes: 200,
    ),
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
    channel.Error(message) -> message
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
    pubsub: Option(PubSub),
    /// Configured coordinator logger, cached for hot message paths.
    logger: Logger,
    /// The coordinator's own subject, used for scheduling timers
    self_subject: Option(Subject(Message)),
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
    /// Wire codec negotiated for this connection. Used to decode inbound
    /// binary frames and encode replies/pushes destined for this socket, so
    /// different connections can use different serializers concurrently.
    codec: Codec,
    /// Topics this socket is subscribed to
    subscribed_topics: Set(String),
    /// Per-topic assigns (topic -> Dynamic assigns)
    channel_assigns: Dict(String, Dynamic),
    /// Per-topic registered channel id (topic -> handler id)
    channel_ids: Dict(String, Int),
    /// Socket-level assigns seeded by the transport connect hook (type-erased).
    /// Used as the initial assigns visible to a channel at join time.
    connect_assigns: Dynamic,
    /// Monotonic timestamp (ms) of the last heartbeat received
    last_heartbeat: Int,
  )
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
  // Channel operations
  HandleBinary(socket_id: String, data: BitArray)
  HandleInfo(
    socket_id: String,
    topic: String,
    channel_id: Int,
    handle_info: fn(SocketContext) -> HandleResultErased,
  )
  /// Raw inbound text from the transport, decoded inside the actor using
  /// the configured codec.
  RouteText(socket_id: String, raw_text: String)
  RouteDecoded(socket_id: String, msg: codec.Inbound)
  // Broadcasting
  Broadcast(
    topic: String,
    event: String,
    payload: json.Json,
    except: Option(String),
  )
  RemoteBroadcast(pubsub.Message)
  // Heartbeat timeout enforcement
  CheckHeartbeats
  Stop(reply: Subject(Nil))
}

/// Erlang monotonic time in milliseconds
@external(erlang, "beryl_ffi", "monotonic_time_ms")
fn monotonic_time_ms() -> Int

/// Coerce an external PubSub record message into the typed PubSub message.
@external(erlang, "beryl_ffi", "identity")
fn coerce_to_pubsub_message(value: Dynamic) -> pubsub.Message

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
  ps: PubSub,
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
  ps: PubSub,
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
  ps: Option(PubSub),
) -> actor.Builder(State, Message, Subject(Message)) {
  let logging = internal_logging(config.logging)
  internal.configure(logging)
  let initial_state =
    State(
      handlers: [],
      next_handler_id: 0,
      sockets: dict.new(),
      topics: dict.new(),
      config: config,
      pubsub: ps,
      logger: internal.logger_with_config("beryl.coordinator", logging),
      self_subject: None,
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
          |> process.select_record(
            atom.create("message"),
            4,
            fn(raw: Dynamic) -> Message {
              RemoteBroadcast(coerce_to_pubsub_message(raw))
            },
          )

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

    HandleBinary(socket_id, data) -> handle_binary_in(state, socket_id, data)

    HandleInfo(socket_id, topic_name, channel_id, callback) ->
      handle_info(state, socket_id, topic_name, channel_id, callback)

    RouteText(socket_id, raw_text) ->
      handle_route_text(state, socket_id, raw_text)

    RouteDecoded(socket_id, msg) -> dispatch_inbound(state, socket_id, msg)

    Broadcast(topic_name, event, payload, except) ->
      handle_broadcast(state, topic_name, event, payload, except)

    RemoteBroadcast(pubsub_msg) -> handle_remote_broadcast(state, pubsub_msg)

    CheckHeartbeats -> handle_check_heartbeats(state)

    Stop(reply) -> handle_stop(state, reply)
  }
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

  rate_limit.stop_optional(state.config.message_limiter)
  rate_limit.stop_optional(state.config.join_limiter)
  rate_limit.stop_optional(state.config.channel_limiter)
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
  let pattern = topic.parse_pattern(pattern_str)
  let already_registered =
    list.any(state.handlers, fn(h) { h.pattern == pattern })

  case already_registered {
    True -> {
      process.send(reply, Error(PatternAlreadyRegistered(pattern_str)))
      actor.continue(state)
    }
    False -> {
      let handler_id = state.next_handler_id
      let registered_handler =
        ChannelHandler(
          id: handler_id,
          pattern: pattern,
          join: handler.join,
          handle_in: handler.handle_in,
          handle_binary: handler.handle_binary,
          terminate: handler.terminate,
        )
      let new_handlers = list.append(state.handlers, [registered_handler])
      process.send(reply, Ok(handler_id))
      actor.continue(
        State(..state, handlers: new_handlers, next_handler_id: handler_id + 1),
      )
    }
  }
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
      codec: option.unwrap(codec, state.config.codec),
      subscribed_topics: set.new(),
      channel_assigns: dict.new(),
      channel_ids: dict.new(),
      connect_assigns: connect_assigns,
      last_heartbeat: monotonic_time_ms(),
    )

  let logger = coordinator_logger(state)
  logger |> log.info("Socket connected", [#("socket_id", socket_id)])
  let new_sockets = dict.insert(state.sockets, socket_id, socket_info)
  actor.continue(State(..state, sockets: new_sockets))
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

fn remove_socket_rate_limits(state: State, socket_id: String) -> Nil {
  rate_limit.remove_by_prefix_optional(
    state.config.message_limiter,
    "msg:" <> socket_id,
  )
  rate_limit.remove_by_prefix_optional(
    state.config.join_limiter,
    "join:" <> socket_id,
  )
  rate_limit.remove_by_prefix_optional(
    state.config.channel_limiter,
    "ch:" <> socket_id <> ":",
  )
}

fn handle_join(
  state: State,
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
) -> actor.Next(State, Message) {
  // Check join rate limit
  case
    rate_limit.check_optional(state.config.join_limiter, "join:" <> socket_id)
  {
    Error(Nil) -> {
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
            socket_info.codec.encode_reply(
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
      actor.continue(state)
    }
    Ok(_) ->
      handle_join_inner(state, socket_id, topic_name, payload, join_ref, ref)
  }
}

fn handle_join_inner(
  state: State,
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: Option(String),
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
      actor.continue(state)
    }
    Ok(socket_info) -> {
      case can_join_topic(socket_info, topic_name, state.config) {
        False -> reject_join_cap(state, socket_info, topic_name, join_ref, ref)
        True ->
          handle_join_with_handler(
            state,
            socket_info,
            socket_id,
            topic_name,
            payload,
            join_ref,
            ref,
          )
      }
    }
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
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  logger
  |> log.warn("Join rejected: topic cap exceeded", [
    #("socket_id", socket_info.id),
    #("topic", topic_name),
  ])
  let reply =
    socket_info.codec.encode_reply(
      join_ref,
      ref,
      topic_name,
      codec.StatusError,
      json.object([#("reason", json.string("too_many_topics"))]),
    )
  let _send_result = send_frame_logged(state, socket_info, topic_name, reply)
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
        socket_info.codec.encode_reply(
          join_ref,
          ref,
          topic_name,
          codec.StatusError,
          json.object([#("reason", json.string("no_channel_handler"))]),
        )
      let _send_result =
        send_frame_logged(state, socket_info, topic_name, reply)
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
      )
  }
}

fn handle_leave(
  state: State,
  socket_id: String,
  topic_name: String,
  ref: Option(String),
) -> actor.Next(State, Message) {
  let state = terminate_channel(state, socket_id, topic_name, channel.Normal)

  case ref, dict.get(state.sockets, socket_id) {
    Some(r), Ok(socket_info) -> {
      let reply =
        socket_info.codec.encode_reply(
          None,
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

  actor.continue(state)
}

fn handle_in(
  state: State,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
) -> actor.Next(State, Message) {
  // Check per-socket message rate limit
  case
    rate_limit.check_optional(state.config.message_limiter, "msg:" <> socket_id)
  {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.warn("Message rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      actor.continue(state)
    }
    Ok(_) -> {
      handle_in_subscribed(state, socket_id, topic_name, event, payload, ref)
    }
  }
}

fn handle_in_subscribed(
  state: State,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
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
      actor.continue(state)
    }
    Ok(socket_info) -> {
      case set.contains(socket_info.subscribed_topics, topic_name) {
        False -> {
          let logger = coordinator_logger(state)
          logger
          |> log.debug("Inbound message ignored", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("event", event),
            #("reason", "topic_not_joined"),
          ])
          actor.continue(state)
        }
        True ->
          handle_in_rate_limited(
            state,
            socket_info,
            socket_id,
            topic_name,
            event,
            payload,
            ref,
          )
      }
    }
  }
}

fn handle_in_rate_limited(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
) -> actor.Next(State, Message) {
  case
    rate_limit.check_capped_optional(
      state.config.channel_limiter,
      "ch:" <> socket_id <> ":" <> topic_name,
      "ch:" <> socket_id <> ":",
      state.config.channel_limiter_max_keys_per_socket,
    )
  {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.warn("Channel rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      actor.continue(state)
    }
    Ok(_) ->
      route_in_to_handler(
        state,
        socket_info,
        socket_id,
        topic_name,
        event,
        payload,
        ref,
      )
  }
}

fn handle_info(
  state: State,
  socket_id: String,
  topic_name: String,
  channel_id: Int,
  callback: fn(SocketContext) -> HandleResultErased,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Handle info ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "socket_not_found"),
      ])
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
          actor.continue(state)
        }
        True ->
          route_info_to_registered_handler(
            state,
            socket_info,
            socket_id,
            topic_name,
            channel_id,
            callback,
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
  case active_codec.decode_binary {
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
  case
    rate_limit.check_optional(state.config.message_limiter, "msg:" <> socket_id)
  {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.warn("Binary message rate limited", [
        #("socket_id", socket_id),
      ])
      actor.continue(state)
    }
    Ok(_) -> handle_raw_binary_in_inner(state, socket_id, data)
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
    Ok(msg) -> dispatch_inbound(state, socket_id, msg)
  }
}

fn handle_raw_binary_in_inner(
  state: State,
  socket_id: String,
  data: BitArray,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Binary message ignored", [
        #("socket_id", socket_id),
        #("reason", "socket_not_found"),
      ])
      actor.continue(state)
    }
    Ok(socket_info) -> {
      let state =
        set.fold(socket_info.subscribed_topics, state, fn(st, topic_name) {
          route_binary_to_handler(
            state,
            st,
            socket_info,
            socket_id,
            topic_name,
            data,
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
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> actor.continue(state)
    Ok(socket_info) -> {
      let updated_socket =
        SocketInfo(..socket_info, last_heartbeat: monotonic_time_ms())
      let new_sockets = dict.insert(state.sockets, socket_id, updated_socket)

      let reply = socket_info.codec.encode_heartbeat_reply(ref)
      let _send_result =
        send_frame_logged(state, socket_info, "__heartbeat__", reply)
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Heartbeat handled", [
        #("socket_id", socket_id),
        #("ref", optional_string(ref)),
      ])
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
      remove_socket_rate_limits(state, socket_id)
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

      State(..state, sockets: new_sockets, topics: new_topics)
    }
  }
}

fn handle_broadcast(
  state: State,
  topic_name: String,
  event: String,
  payload: json.Json,
  except: Option(String),
) -> actor.Next(State, Message) {
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
  list.each(recipients, fn(socket_id) {
    case dict.get(state.sockets, socket_id) {
      Ok(socket_info) -> {
        // Encode per recipient so connections negotiating different
        // serializers each receive a frame in their own wire format.
        let msg = socket_info.codec.encode_push(topic_name, event, payload)
        let _send_result =
          send_frame_logged(state, socket_info, topic_name, msg)
        Nil
      }
      Error(Nil) -> Nil
    }
  })

  actor.continue(state)
}

fn handle_remote_broadcast(
  state: State,
  pubsub_msg: pubsub.Message,
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

/// Update assigns for a socket/topic
fn update_assigns(
  state: State,
  socket_id: String,
  topic_name: String,
  assigns: Dynamic,
) -> State {
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> state
    Ok(socket_info) -> {
      let new_assigns =
        dict.insert(socket_info.channel_assigns, topic_name, assigns)
      let new_socket_info =
        SocketInfo(..socket_info, channel_assigns: new_assigns)
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

// nolint: unused_exports -- public transport API for callers that decode frames before routing
/// Route a transport-decoded inbound message to the coordinator.
pub fn route_decoded(
  coord: Subject(Message),
  socket_id: String,
  msg: codec.Inbound,
) -> Nil {
  process.send(coord, RouteDecoded(socket_id, msg))
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
  case active_codec.decode_text(raw_text) {
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
            #("topic", topic.sanitize_for_log(msg.topic)),
            #("event", topic.sanitize_for_log(inbound_kind(msg.kind))),
            #("ref", optional_string(msg.ref)),
            #("join_ref", optional_string(msg.join_ref)),
          ],
          internal.preview_metadata("frame_preview", raw_text, logging),
        ),
      )
      dispatch_inbound(state, socket_id, msg)
    }
  }
}

fn dispatch_inbound(
  state: State,
  socket_id: String,
  msg: codec.Inbound,
) -> actor.Next(State, Message) {
  case msg.kind {
    codec.Join ->
      case is_valid_topic(msg.topic, state.config) {
        True ->
          handle_join(
            state,
            socket_id,
            msg.topic,
            msg.payload,
            msg.join_ref,
            msg.ref,
          )
        False -> reject_invalid_join(state, socket_id, msg)
      }
    codec.Leave ->
      case is_valid_topic(msg.topic, state.config) {
        False -> {
          let safe_topic = topic.sanitize_for_log(msg.topic)
          coordinator_logger(state)
          |> log.warn("Leave dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", safe_topic),
          ])
          actor.continue(state)
        }
        True -> handle_leave(state, socket_id, msg.topic, msg.ref)
      }
    codec.Heartbeat -> handle_heartbeat(state, socket_id, msg.ref)
    codec.Event(event) -> {
      let resolved = resolve_event_topic(state, socket_id, msg.topic)
      case
        is_valid_topic(resolved, state.config),
        is_valid_event(event, state.config)
      {
        True, True ->
          handle_in(state, socket_id, resolved, event, msg.payload, msg.ref)
        False, _ -> {
          let safe_topic = topic.sanitize_for_log(msg.topic)
          let safe_event = topic.sanitize_for_log(event)
          coordinator_logger(state)
          |> log.warn("Event dropped: invalid topic", [
            #("socket_id", socket_id),
            #("topic", safe_topic),
            #("event", safe_event),
          ])
          actor.continue(state)
        }
        True, False -> {
          let safe_event = topic.sanitize_for_log(event)
          coordinator_logger(state)
          |> log.warn("Event dropped: invalid event", [
            #("socket_id", socket_id),
            #("topic", msg.topic),
            #("event", safe_event),
          ])
          actor.continue(state)
        }
      }
    }
  }
}

/// Resolve the topic for an inbound Event. Some codecs (e.g. Socket.IO/Fluid)
/// omit a per-frame topic; in that case route to the socket's single joined
/// topic. With zero or multiple joined topics the original (empty) topic is
/// returned so existing validation drops it. Topic-carrying codecs (Phoenix)
/// are unaffected.
fn resolve_event_topic(
  state: State,
  socket_id: String,
  requested: String,
) -> String {
  case requested {
    "" ->
      case dict.get(state.sockets, socket_id) {
        Ok(info) ->
          case set.to_list(info.subscribed_topics) {
            [only] -> only
            _ -> requested
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

fn is_valid_event(event_name: String, config: CoordinatorConfig) -> Bool {
  string.byte_size(event_name) <= config.max_event_length
  && result.is_ok(topic.validate_event(event_name))
}

/// Send a `phx_reply` error for a join with an invalid topic and drop the message.
fn reject_invalid_join(
  state: State,
  socket_id: String,
  msg: codec.Inbound,
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  let safe_topic = topic.sanitize_for_log(msg.topic)
  logger
  |> log.warn("Join rejected: invalid topic", [
    #("socket_id", socket_id),
    #("topic", safe_topic),
  ])
  case dict.get(state.sockets, socket_id) {
    Error(Nil) -> actor.continue(state)
    Ok(socket_info) -> {
      let reply =
        socket_info.codec.encode_reply(
          msg.join_ref,
          msg.ref,
          msg.topic,
          codec.StatusError,
          json.object([#("reason", json.string("invalid_topic"))]),
        )
      let _send_result =
        send_frame_logged(state, socket_info, safe_topic, reply)
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
      assigns: socket_info.connect_assigns,
      send: socket_info.send,
      send_binary: socket_info.send_binary,
    )

  case handler.join(topic_name, payload, ctx) {
    JoinErrorErased(reason) -> {
      logger
      |> log.debug("Join rejected", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("ref", optional_string(ref)),
        #("join_ref", optional_string(join_ref)),
      ])
      let reply =
        socket_info.codec.encode_reply(
          join_ref,
          ref,
          topic_name,
          codec.StatusError,
          reason,
        )
      let _send_result =
        send_frame_logged(state, socket_info, topic_name, reply)
      actor.continue(state)
    }
    JoinOkErased(reply_payload, assigns) -> {
      logger
      |> log.debug("Join accepted", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("ref", optional_string(ref)),
        #("join_ref", optional_string(join_ref)),
      ])
      let new_subscribed = set.insert(socket_info.subscribed_topics, topic_name)
      let new_assigns =
        dict.insert(socket_info.channel_assigns, topic_name, assigns)
      let new_channel_ids =
        dict.insert(socket_info.channel_ids, topic_name, handler.id)
      let new_socket_info =
        SocketInfo(
          ..socket_info,
          subscribed_topics: new_subscribed,
          channel_assigns: new_assigns,
          channel_ids: new_channel_ids,
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
        socket_info.codec.encode_reply(
          join_ref,
          ref,
          topic_name,
          codec.StatusOk,
          response,
        )
      let _send_result =
        send_frame_logged(state, socket_info, topic_name, reply)

      actor.continue(State(..state, sockets: new_sockets, topics: new_topics))
    }
  }
}

fn dispatch_handle_in(
  state: State,
  socket_info: SocketInfo,
  handler: ChannelHandler,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  logger
  |> log.debug("Inbound message routed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
    #("event", event),
    #("ref", optional_string(ref)),
  ])
  let assigns =
    dict.get(socket_info.channel_assigns, topic_name)
    |> result.unwrap(dynamic.nil())

  let ctx =
    SocketContext(
      socket_id: socket_id,
      topic: topic_name,
      assigns: assigns,
      send: socket_info.send,
      send_binary: socket_info.send_binary,
    )

  case handler.handle_in(event, payload, ctx) {
    NoReplyErased(new_assigns) -> {
      logger
      |> log.debug("Channel callback returned no reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
      ])
      let state = update_assigns(state, socket_id, topic_name, new_assigns)
      actor.continue(state)
    }

    ReplyErased(_reply_event, reply_payload, new_assigns) -> {
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
            socket_info.codec.encode_reply(
              None,
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
      let state = update_assigns(state, socket_id, topic_name, new_assigns)
      actor.continue(state)
    }

    PushErased(push_event, push_payload, new_assigns) -> {
      logger
      |> log.debug("Channel callback returned push", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("push_event", push_event),
      ])
      let msg =
        socket_info.codec.encode_push(topic_name, push_event, push_payload)
      let _send_result = send_frame_logged(state, socket_info, topic_name, msg)
      let state = update_assigns(state, socket_id, topic_name, new_assigns)
      actor.continue(state)
    }

    StopErased(reason) -> {
      logger
      |> log.debug("Channel callback stopped channel", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("reason", stop_reason(reason)),
      ])
      let state = terminate_channel(state, socket_id, topic_name, reason)
      actor.continue(state)
    }
  }
}

fn dispatch_handle_info(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  callback: fn(SocketContext) -> HandleResultErased,
) -> actor.Next(State, Message) {
  let logger = coordinator_logger(state)
  logger
  |> log.debug("Handle info routed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
  ])
  let assigns =
    dict.get(socket_info.channel_assigns, topic_name)
    |> result.unwrap(dynamic.nil())

  let ctx =
    SocketContext(
      socket_id: socket_id,
      topic: topic_name,
      assigns: assigns,
      send: socket_info.send,
      send_binary: socket_info.send_binary,
    )

  case callback(ctx) {
    NoReplyErased(new_assigns) -> {
      logger
      |> log.debug("Channel callback returned no reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_info"),
      ])
      let state = update_assigns(state, socket_id, topic_name, new_assigns)
      actor.continue(state)
    }

    ReplyErased(reply_event, reply_payload, new_assigns)
    | PushErased(reply_event, reply_payload, new_assigns) -> {
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
        socket_info.codec.encode_push(topic_name, reply_event, reply_payload)
      let _send_result = send_frame_logged(state, socket_info, topic_name, msg)
      let state = update_assigns(state, socket_id, topic_name, new_assigns)
      actor.continue(state)
    }

    StopErased(reason) -> {
      logger
      |> log.debug("Channel callback stopped channel", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_info"),
        #("reason", stop_reason(reason)),
      ])
      let state = terminate_channel(state, socket_id, topic_name, reason)
      actor.continue(state)
    }
  }
}

fn dispatch_handle_binary(
  _state: State,
  st: State,
  socket_info: SocketInfo,
  handler: ChannelHandler,
  socket_id: String,
  topic_name: String,
  data: BitArray,
) -> State {
  let logger = coordinator_logger(st)
  logger
  |> log.debug("Binary message routed", [
    #("socket_id", socket_id),
    #("topic", topic_name),
  ])
  let assigns =
    dict.get(socket_info.channel_assigns, topic_name)
    |> result.unwrap(dynamic.nil())

  let ctx =
    SocketContext(
      socket_id: socket_id,
      topic: topic_name,
      assigns: assigns,
      send: socket_info.send,
      send_binary: socket_info.send_binary,
    )

  case handler.handle_binary(data, ctx) {
    NoReplyErased(new_assigns) -> {
      logger
      |> log.debug("Channel callback returned no reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_binary"),
      ])
      update_assigns(st, socket_id, topic_name, new_assigns)
    }
    ReplyErased(_event, reply_payload, new_assigns) -> {
      logger
      |> log.debug("Channel callback returned reply", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_binary"),
      ])
      let msg =
        socket_info.codec.encode_push(topic_name, "binary_reply", reply_payload)
      let _send_result = send_frame_logged(st, socket_info, topic_name, msg)
      update_assigns(st, socket_id, topic_name, new_assigns)
    }
    PushErased(push_event, push_payload, new_assigns) -> {
      logger
      |> log.debug("Channel callback returned push", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_binary"),
        #("push_event", push_event),
      ])
      let msg =
        socket_info.codec.encode_push(topic_name, push_event, push_payload)
      let _send_result = send_frame_logged(st, socket_info, topic_name, msg)
      update_assigns(st, socket_id, topic_name, new_assigns)
    }
    StopErased(reason) -> {
      logger
      |> log.debug("Channel callback stopped channel", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("callback", "handle_binary"),
        #("reason", stop_reason(reason)),
      ])
      terminate_channel(st, socket_id, topic_name, reason)
    }
  }
}

fn do_terminate_channel(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  reason: StopReason,
) -> State {
  case find_joined_handler(state, socket_info, topic_name) {
    Some(handler) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Channel terminated", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", stop_reason(reason)),
      ])
      let assigns =
        dict.get(socket_info.channel_assigns, topic_name)
        |> result.unwrap(dynamic.nil())

      let ctx =
        SocketContext(
          socket_id: socket_id,
          topic: topic_name,
          assigns: assigns,
          send: socket_info.send,
          send_binary: socket_info.send_binary,
        )
      handler.terminate(reason, ctx)
    }
    None -> Nil
  }

  rate_limit.remove_optional(
    state.config.channel_limiter,
    "ch:" <> socket_id <> ":" <> topic_name,
  )

  let new_subscribed = set.delete(socket_info.subscribed_topics, topic_name)
  let new_assigns = dict.delete(socket_info.channel_assigns, topic_name)
  let new_channel_ids = dict.delete(socket_info.channel_ids, topic_name)
  let new_socket_info =
    SocketInfo(
      ..socket_info,
      subscribed_topics: new_subscribed,
      channel_assigns: new_assigns,
      channel_ids: new_channel_ids,
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
) -> actor.Next(State, Message) {
  case find_joined_handler(state, socket_info, topic_name) {
    None -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Inbound message ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("event", event),
        #("reason", "handler_not_found"),
      ])
      actor.continue(state)
    }
    Some(handler) ->
      dispatch_handle_in(
        state,
        socket_info,
        handler,
        socket_id,
        topic_name,
        event,
        payload,
        ref,
      )
  }
}

fn route_info_to_registered_handler(
  state: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  channel_id: Int,
  callback: fn(SocketContext) -> HandleResultErased,
) -> actor.Next(State, Message) {
  case dict.get(socket_info.channel_ids, topic_name) {
    Error(Nil) -> {
      let logger = coordinator_logger(state)
      logger
      |> log.debug("Handle info ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "channel_id_not_found"),
      ])
      actor.continue(state)
    }
    Ok(joined_channel_id) -> {
      case joined_channel_id == channel_id {
        True ->
          dispatch_handle_info(
            state,
            socket_info,
            socket_id,
            topic_name,
            callback,
          )
        False -> {
          let logger = coordinator_logger(state)
          logger
          |> log.debug("Handle info ignored", [
            #("socket_id", socket_id),
            #("topic", topic_name),
            #("reason", "registered_channel_mismatch"),
          ])
          actor.continue(state)
        }
      }
    }
  }
}

fn find_handler_by_id(
  handlers: List(ChannelHandler),
  handler_id: Int,
) -> Option(ChannelHandler) {
  list.find(handlers, fn(h) { h.id == handler_id })
  |> option.from_result()
}

fn find_joined_handler(
  state: State,
  socket_info: SocketInfo,
  topic_name: String,
) -> Option(ChannelHandler) {
  case dict.get(socket_info.channel_ids, topic_name) {
    Ok(handler_id) -> find_handler_by_id(state.handlers, handler_id)
    Error(Nil) -> None
  }
}

fn route_binary_to_handler(
  state: State,
  st: State,
  socket_info: SocketInfo,
  socket_id: String,
  topic_name: String,
  data: BitArray,
) -> State {
  case find_joined_handler(st, socket_info, topic_name) {
    None -> {
      let logger = coordinator_logger(st)
      logger
      |> log.debug("Binary message ignored", [
        #("socket_id", socket_id),
        #("topic", topic_name),
        #("reason", "handler_not_found"),
      ])
      st
    }
    Some(handler) ->
      dispatch_handle_binary(
        state,
        st,
        socket_info,
        handler,
        socket_id,
        topic_name,
        data,
      )
  }
}
