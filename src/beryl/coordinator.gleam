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
import beryl/pubsub.{type PubSub}
import beryl/rate_limit.{type RateLimiter}
import beryl/topic.{type TopicPattern}
import beryl/wire/codec.{type Codec}
import birch/logger as log
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

/// Type-erased channel handler for storage
/// The actual typed Channel is converted to this for the registry
pub type ChannelHandler {
  ChannelHandler(
    pattern: TopicPattern,
    join: fn(String, Dynamic, SocketContext) -> JoinResultErased,
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
    /// Current assigns for this socket/topic (type-erased)
    assigns: Dynamic,
    /// Function to send text messages to this socket
    send: fn(String) -> Result(Nil, Nil),
    /// Function to send binary data to this socket
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    /// PID of the WebSocket handler process (for direct messaging)
    handler_pid: Dynamic,
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
  InvalidPattern(String)
}

/// Errors when starting the coordinator
pub type StartError {
  /// heartbeat_timeout_ms must be > 0 when heartbeat checking is enabled
  InvalidHeartbeatTimeout
  /// The underlying OTP actor failed to start
  ActorStartFailed(actor.StartError)
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
  )
}

/// Internal state for coordinator actor
pub type State {
  State(
    /// Pattern -> handler (ordered list for matching)
    handlers: List(ChannelHandler),
    /// Socket ID -> socket info
    sockets: Dict(String, SocketInfo),
    /// Topic -> set of socket IDs subscribed
    topics: Dict(String, Set(String)),
    /// Heartbeat timeout configuration
    config: CoordinatorConfig,
    /// Optional PubSub for distributed broadcasts
    pubsub: Option(PubSub),
    /// The coordinator's own subject, used for scheduling timers
    self_subject: Option(Subject(Message)),
  )
}

/// Info tracked per socket
pub type SocketInfo {
  SocketInfo(
    id: String,
    /// Function to send text to this socket's WebSocket
    send: fn(String) -> Result(Nil, Nil),
    /// Function to send binary to this socket's WebSocket
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    /// PID of the WebSocket handler process (for direct messaging)
    handler_pid: Dynamic,
    /// Topics this socket is subscribed to
    subscribed_topics: Set(String),
    /// Per-topic assigns (topic -> Dynamic assigns)
    channel_assigns: Dict(String, Dynamic),
    /// Monotonic timestamp (ms) of the last heartbeat received
    last_heartbeat: Int,
  )
}

/// Messages the coordinator handles
pub type Message {
  // Channel registration
  RegisterChannel(
    pattern: String,
    handler: ChannelHandler,
    reply: Subject(Result(Nil, RegisterError)),
  )
  // Socket lifecycle
  SocketConnected(
    socket_id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    handler_pid: Dynamic,
  )
  SocketDisconnected(socket_id: String)
  // Channel operations
  Join(
    socket_id: String,
    topic: String,
    payload: Dynamic,
    join_ref: Option(String),
    ref: String,
  )
  Leave(socket_id: String, topic: String, ref: Option(String))
  HandleIn(
    socket_id: String,
    topic: String,
    event: String,
    payload: Dynamic,
    ref: Option(String),
  )
  HandleBinary(socket_id: String, data: BitArray)
  HandleInfo(socket_id: String, topic: String, message: Dynamic)
  Heartbeat(socket_id: String, ref: String)
  /// Raw inbound text from the transport — decoded inside the actor using
  /// the configured codec.
  RouteText(socket_id: String, raw_text: String)
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
  case validate_config(config) {
    Error(e) -> Error(e)
    Ok(Nil) ->
      build_coordinator(config, None)
      |> actor.start
      |> result.map(fn(started) { started.data })
      |> result.map_error(ActorStartFailed)
  }
}

/// Start the coordinator actor with heartbeat timeout enforcement and PubSub.
pub fn start_with_config_and_pubsub(
  config: CoordinatorConfig,
  ps: PubSub,
) -> Result(Subject(Message), StartError) {
  case validate_config(config) {
    Error(e) -> Error(e)
    Ok(Nil) ->
      build_coordinator(config, Some(ps))
      |> actor.start
      |> result.map(fn(started) { started.data })
      |> result.map_error(ActorStartFailed)
  }
}

/// Start the coordinator with a registered name (for supervision)
pub fn start_named(
  config: CoordinatorConfig,
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), StartError) {
  case validate_config(config) {
    Error(e) -> Error(e)
    Ok(Nil) ->
      build_coordinator(config, None)
      |> actor.named(name)
      |> actor.start
      |> result.map_error(ActorStartFailed)
  }
}

/// Start a named coordinator actor with PubSub.
pub fn start_named_with_pubsub(
  config: CoordinatorConfig,
  ps: PubSub,
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), StartError) {
  case validate_config(config) {
    Error(e) -> Error(e)
    Ok(Nil) ->
      build_coordinator(config, Some(ps))
      |> actor.named(name)
      |> actor.start
      |> result.map_error(ActorStartFailed)
  }
}

fn validate_config(config: CoordinatorConfig) -> Result(Nil, StartError) {
  case
    config.heartbeat_check_interval_ms > 0 && config.heartbeat_timeout_ms <= 0
  {
    True -> Error(InvalidHeartbeatTimeout)
    False -> Ok(Nil)
  }
}

fn build_coordinator(
  config: CoordinatorConfig,
  ps: Option(PubSub),
) -> actor.Builder(State, Message, Subject(Message)) {
  let initial_state =
    State(
      handlers: [],
      sockets: dict.new(),
      topics: dict.new(),
      config: config,
      pubsub: ps,
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
  case config.heartbeat_check_interval_ms > 0 {
    True -> {
      let _ =
        process.send_after(
          subject,
          config.heartbeat_check_interval_ms,
          CheckHeartbeats,
        )
      Nil
    }
    False -> Nil
  }
}

/// Handle incoming messages
fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    RegisterChannel(pattern, handler, reply) ->
      handle_register_channel(state, pattern, handler, reply)

    SocketConnected(socket_id, send, send_binary, handler_pid) ->
      handle_socket_connected(state, socket_id, send, send_binary, handler_pid)

    SocketDisconnected(socket_id) ->
      handle_socket_disconnected(state, socket_id)

    Join(socket_id, topic_name, payload, join_ref, ref) ->
      handle_join(state, socket_id, topic_name, payload, join_ref, ref)

    Leave(socket_id, topic_name, ref) ->
      handle_leave(state, socket_id, topic_name, ref)

    HandleIn(socket_id, topic_name, event, payload, ref) ->
      handle_in(state, socket_id, topic_name, event, payload, ref)

    HandleBinary(socket_id, data) -> handle_binary_in(state, socket_id, data)

    HandleInfo(socket_id, topic_name, message) ->
      handle_info(state, socket_id, topic_name, message)

    Heartbeat(socket_id, ref) -> handle_heartbeat(state, socket_id, ref)

    RouteText(socket_id, raw_text) ->
      handle_route_text(state, socket_id, raw_text)

    Broadcast(topic_name, event, payload, except) ->
      handle_broadcast(state, topic_name, event, payload, except)

    RemoteBroadcast(pubsub_msg) -> handle_remote_broadcast(state, pubsub_msg)

    CheckHeartbeats -> handle_check_heartbeats(state)
  }
}

fn handle_register_channel(
  state: State,
  pattern_str: String,
  handler: ChannelHandler,
  reply: Subject(Result(Nil, RegisterError)),
) -> actor.Next(State, Message) {
  let pattern = topic.parse_pattern(pattern_str)
  let already_registered =
    list.any(state.handlers, fn(h) { h.pattern == pattern })

  case already_registered {
    True -> {
      process.send(reply, Error(PatternAlreadyRegistered(pattern_str)))
      actor.continue(state)
    }
    False -> {
      let new_handlers = list.append(state.handlers, [handler])
      process.send(reply, Ok(Nil))
      actor.continue(State(..state, handlers: new_handlers))
    }
  }
}

fn handle_socket_connected(
  state: State,
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  handler_pid: Dynamic,
) -> actor.Next(State, Message) {
  let socket_info =
    SocketInfo(
      id: socket_id,
      send: send,
      send_binary: send_binary,
      handler_pid: handler_pid,
      subscribed_topics: set.new(),
      channel_assigns: dict.new(),
      last_heartbeat: monotonic_time_ms(),
    )

  let logger = internal.logger("beryl.coordinator")
  logger |> log.info("Socket connected", [#("socket_id", socket_id)])
  let new_sockets = dict.insert(state.sockets, socket_id, socket_info)
  actor.continue(State(..state, sockets: new_sockets))
}

fn handle_socket_disconnected(
  state: State,
  socket_id: String,
) -> actor.Next(State, Message) {
  let logger = internal.logger("beryl.coordinator")
  logger |> log.info("Socket disconnected", [#("socket_id", socket_id)])
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
  actor.continue(disconnect_socket(state, socket_id, channel.Normal))
}

fn handle_join(
  state: State,
  socket_id: String,
  topic_name: String,
  payload: Dynamic,
  join_ref: Option(String),
  ref: String,
) -> actor.Next(State, Message) {
  // Check join rate limit
  case
    rate_limit.check_optional(state.config.join_limiter, "join:" <> socket_id)
  {
    Error(_) -> {
      let logger = internal.logger("beryl.coordinator")
      logger
      |> log.warn("Join rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      // Send error reply to client
      case dict.get(state.sockets, socket_id) {
        Ok(socket_info) -> {
          let reply =
            state.config.codec.encode_reply(
              join_ref,
              ref,
              topic_name,
              codec.StatusError,
              json.object([#("reason", json.string("rate_limited"))]),
            )
          let _ = socket_info.send(reply)
          Nil
        }
        Error(_) -> Nil
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
  ref: String,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(_) -> actor.continue(state)
    Ok(socket_info) -> {
      case find_handler(state.handlers, topic_name) {
        None -> {
          let reply =
            state.config.codec.encode_reply(
              join_ref,
              ref,
              topic_name,
              codec.StatusError,
              json.object([#("reason", json.string("no_channel_handler"))]),
            )
          let _ = socket_info.send(reply)
          actor.continue(state)
        }
        Some(handler) -> {
          let ctx =
            SocketContext(
              socket_id: socket_id,
              topic: topic_name,
              assigns: dynamic.nil(),
              send: socket_info.send,
              send_binary: socket_info.send_binary,
              handler_pid: socket_info.handler_pid,
            )

          case handler.join(topic_name, payload, ctx) {
            JoinErrorErased(reason) -> {
              let reply =
                state.config.codec.encode_reply(
                  join_ref,
                  ref,
                  topic_name,
                  codec.StatusError,
                  reason,
                )
              let _ = socket_info.send(reply)
              actor.continue(state)
            }
            JoinOkErased(reply_payload, assigns) -> {
              let new_subscribed =
                set.insert(socket_info.subscribed_topics, topic_name)
              let new_assigns =
                dict.insert(socket_info.channel_assigns, topic_name, assigns)
              let new_socket_info =
                SocketInfo(
                  ..socket_info,
                  subscribed_topics: new_subscribed,
                  channel_assigns: new_assigns,
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

              let new_topics =
                dict.insert(state.topics, topic_name, topic_subscribers)
              let new_sockets =
                dict.insert(state.sockets, socket_id, new_socket_info)

              let response = case reply_payload {
                None -> json.object([])
                Some(p) -> p
              }
              let reply =
                state.config.codec.encode_reply(
                  join_ref,
                  ref,
                  topic_name,
                  codec.StatusOk,
                  response,
                )
              let _ = socket_info.send(reply)

              actor.continue(
                State(..state, sockets: new_sockets, topics: new_topics),
              )
            }
          }
        }
      }
    }
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
        state.config.codec.encode_reply(
          None,
          r,
          topic_name,
          codec.StatusOk,
          json.object([]),
        )
      let _ = socket_info.send(reply)
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
    Error(_) -> {
      let logger = internal.logger("beryl.coordinator")
      logger
      |> log.warn("Message rate limited", [
        #("socket_id", socket_id),
        #("topic", topic_name),
      ])
      actor.continue(state)
    }
    Ok(_) -> {
      // Check per-channel message rate limit
      case
        rate_limit.check_optional(
          state.config.channel_limiter,
          "ch:" <> socket_id <> ":" <> topic_name,
        )
      {
        Error(_) -> {
          let logger = internal.logger("beryl.coordinator")
          logger
          |> log.warn("Channel rate limited", [
            #("socket_id", socket_id),
            #("topic", topic_name),
          ])
          actor.continue(state)
        }
        Ok(_) ->
          handle_in_inner(state, socket_id, topic_name, event, payload, ref)
      }
    }
  }
}

fn handle_in_inner(
  state: State,
  socket_id: String,
  topic_name: String,
  event: String,
  payload: Dynamic,
  ref: Option(String),
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(_) -> actor.continue(state)
    Ok(socket_info) -> {
      case set.contains(socket_info.subscribed_topics, topic_name) {
        False -> actor.continue(state)
        True -> {
          case find_handler(state.handlers, topic_name) {
            None -> actor.continue(state)
            Some(handler) -> {
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
                  handler_pid: socket_info.handler_pid,
                )

              case handler.handle_in(event, payload, ctx) {
                NoReplyErased(new_assigns) -> {
                  let state =
                    update_assigns(state, socket_id, topic_name, new_assigns)
                  actor.continue(state)
                }

                ReplyErased(_reply_event, reply_payload, new_assigns) -> {
                  case ref {
                    Some(r) -> {
                      let reply =
                        state.config.codec.encode_reply(
                          None,
                          r,
                          topic_name,
                          codec.StatusOk,
                          reply_payload,
                        )
                      let _ = socket_info.send(reply)
                      Nil
                    }
                    None -> Nil
                  }
                  let state =
                    update_assigns(state, socket_id, topic_name, new_assigns)
                  actor.continue(state)
                }

                PushErased(push_event, push_payload, new_assigns) -> {
                  let msg =
                    state.config.codec.encode_push(
                      topic_name,
                      push_event,
                      push_payload,
                    )
                  let _ = socket_info.send(msg)
                  let state =
                    update_assigns(state, socket_id, topic_name, new_assigns)
                  actor.continue(state)
                }

                StopErased(reason) -> {
                  let state =
                    terminate_channel(state, socket_id, topic_name, reason)
                  actor.continue(state)
                }
              }
            }
          }
        }
      }
    }
  }
}

fn handle_info(
  state: State,
  socket_id: String,
  topic_name: String,
  message: Dynamic,
) -> actor.Next(State, Message) {
  handle_info_inner(state, socket_id, topic_name, message)
}

fn handle_info_inner(
  state: State,
  socket_id: String,
  topic_name: String,
  message: Dynamic,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(_) -> actor.continue(state)
    Ok(socket_info) -> {
      case set.contains(socket_info.subscribed_topics, topic_name) {
        False -> actor.continue(state)
        True -> {
          case find_handler(state.handlers, topic_name) {
            None -> actor.continue(state)
            Some(handler) -> {
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
                  handler_pid: socket_info.handler_pid,
                )

              case handler.handle_info(message, ctx) {
                NoReplyErased(new_assigns) -> {
                  let state =
                    update_assigns(state, socket_id, topic_name, new_assigns)
                  actor.continue(state)
                }

                ReplyErased(reply_event, reply_payload, new_assigns) -> {
                  let msg =
                    state.config.codec.encode_push(
                      topic_name,
                      reply_event,
                      reply_payload,
                    )
                  let _ = socket_info.send(msg)
                  let state =
                    update_assigns(state, socket_id, topic_name, new_assigns)
                  actor.continue(state)
                }

                PushErased(push_event, push_payload, new_assigns) -> {
                  let msg =
                    state.config.codec.encode_push(
                      topic_name,
                      push_event,
                      push_payload,
                    )
                  let _ = socket_info.send(msg)
                  let state =
                    update_assigns(state, socket_id, topic_name, new_assigns)
                  actor.continue(state)
                }

                StopErased(reason) -> {
                  let state =
                    terminate_channel(state, socket_id, topic_name, reason)
                  actor.continue(state)
                }
              }
            }
          }
        }
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
  // Check per-socket message rate limit (binary shares with text)
  case
    rate_limit.check_optional(state.config.message_limiter, "msg:" <> socket_id)
  {
    Error(_) -> {
      let logger = internal.logger("beryl.coordinator")
      logger
      |> log.warn("Binary message rate limited", [
        #("socket_id", socket_id),
      ])
      actor.continue(state)
    }
    Ok(_) -> handle_binary_in_inner(state, socket_id, data)
  }
}

fn handle_binary_in_inner(
  state: State,
  socket_id: String,
  data: BitArray,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(_) -> actor.continue(state)
    Ok(socket_info) -> {
      let state =
        set.fold(socket_info.subscribed_topics, state, fn(st, topic_name) {
          case find_handler(st.handlers, topic_name) {
            None -> st
            Some(handler) -> {
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
                  handler_pid: socket_info.handler_pid,
                )

              case handler.handle_binary(data, ctx) {
                NoReplyErased(new_assigns) ->
                  update_assigns(st, socket_id, topic_name, new_assigns)
                ReplyErased(_event, reply_payload, new_assigns) -> {
                  let msg =
                    state.config.codec.encode_push(
                      topic_name,
                      "binary_reply",
                      reply_payload,
                    )
                  let _ = socket_info.send(msg)
                  update_assigns(st, socket_id, topic_name, new_assigns)
                }
                PushErased(push_event, push_payload, new_assigns) -> {
                  let msg =
                    state.config.codec.encode_push(
                      topic_name,
                      push_event,
                      push_payload,
                    )
                  let _ = socket_info.send(msg)
                  update_assigns(st, socket_id, topic_name, new_assigns)
                }
                StopErased(reason) ->
                  terminate_channel(st, socket_id, topic_name, reason)
              }
            }
          }
        })
      actor.continue(state)
    }
  }
}

fn handle_heartbeat(
  state: State,
  socket_id: String,
  ref: String,
) -> actor.Next(State, Message) {
  case dict.get(state.sockets, socket_id) {
    Error(_) -> actor.continue(state)
    Ok(socket_info) -> {
      let updated_socket =
        SocketInfo(..socket_info, last_heartbeat: monotonic_time_ms())
      let new_sockets = dict.insert(state.sockets, socket_id, updated_socket)

      let reply = state.config.codec.encode_heartbeat_reply(ref)
      let _ = socket_info.send(reply)
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

  let logger = internal.logger("beryl.coordinator")
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
    Error(_) -> state
    Ok(socket_info) -> {
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

  let msg = state.config.codec.encode_push(topic_name, event, payload)
  list.each(recipients, fn(socket_id) {
    case dict.get(state.sockets, socket_id) {
      Ok(socket_info) -> {
        let _ = socket_info.send(msg)
        Nil
      }
      Error(_) -> Nil
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
    Error(_) -> state
    Ok(socket_info) -> {
      case set.contains(socket_info.subscribed_topics, topic_name) {
        False -> state
        True -> {
          case find_handler(state.handlers, topic_name) {
            Some(handler) -> {
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
                  handler_pid: socket_info.handler_pid,
                )
              handler.terminate(reason, ctx)
            }
            None -> Nil
          }

          let new_subscribed =
            set.delete(socket_info.subscribed_topics, topic_name)
          let new_assigns = dict.delete(socket_info.channel_assigns, topic_name)
          let new_socket_info =
            SocketInfo(
              ..socket_info,
              subscribed_topics: new_subscribed,
              channel_assigns: new_assigns,
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

          let new_sockets =
            dict.insert(state.sockets, socket_id, new_socket_info)

          State(..state, sockets: new_sockets, topics: new_topics)
        }
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
    Error(_) -> state
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
/// The coordinator decodes the text using its configured `Codec` inside
/// the actor (so the codec lives in one place, not in every transport).
/// Frames that fail to decode are logged and dropped.
pub fn route_message(
  coord: Subject(Message),
  socket_id: String,
  raw_text: String,
) -> Nil {
  process.send(coord, RouteText(socket_id, raw_text))
}

fn handle_route_text(
  state: State,
  socket_id: String,
  raw_text: String,
) -> actor.Next(State, Message) {
  let codec_value = state.config.codec
  case codec_value.decode(raw_text) {
    Error(_) -> {
      let logger = internal.logger("beryl.coordinator")
      logger
      |> log.warn("Failed to decode wire protocol message", [
        #("socket_id", socket_id),
      ])
      actor.continue(state)
    }
    Ok(msg) -> {
      case msg.event {
        e if e == codec_value.join_event -> {
          let ref = option.unwrap(msg.ref, "")
          handle_join(
            state,
            socket_id,
            msg.topic,
            msg.payload,
            msg.join_ref,
            ref,
          )
        }
        e if e == codec_value.leave_event ->
          handle_leave(state, socket_id, msg.topic, msg.ref)
        e if e == codec_value.heartbeat_event -> {
          let ref = option.unwrap(msg.ref, "")
          handle_heartbeat(state, socket_id, ref)
        }
        event ->
          handle_in(state, socket_id, msg.topic, event, msg.payload, msg.ref)
      }
    }
  }
}

/// Route a binary WebSocket frame to the coordinator.
///
/// Binary frames bypass the Phoenix wire protocol and are dispatched
/// to all subscribed topics for the socket.
pub fn route_binary(
  coord: Subject(Message),
  socket_id: String,
  data: BitArray,
) -> Nil {
  process.send(coord, HandleBinary(socket_id, data))
}
