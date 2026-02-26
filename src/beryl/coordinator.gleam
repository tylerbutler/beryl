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
import beryl/topic.{type TopicPattern}
import beryl/wire
import birch/logger
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

/// Type-erased channel handler for storage
/// The actual typed Channel is converted to this for the registry
pub type ChannelHandler {
  ChannelHandler(
    pattern: TopicPattern,
    join: fn(String, Dynamic, SocketContext) -> JoinResultErased,
    handle_in: fn(String, Dynamic, SocketContext) -> HandleResultErased,
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
    /// Function to send messages to this socket
    send: fn(String) -> Result(Nil, Nil),
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
    /// How often to check for stale sockets, in milliseconds.
    /// Set to 0 to disable automatic heartbeat checking.
    heartbeat_check_interval_ms: Int,
    /// Disconnect sockets that haven't sent a heartbeat within this duration
    heartbeat_timeout_ms: Int,
  )
}

/// Default coordinator configuration (no automatic heartbeat enforcement)
pub fn default_config() -> CoordinatorConfig {
  CoordinatorConfig(
    heartbeat_check_interval_ms: 0,
    heartbeat_timeout_ms: 60_000,
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
  Heartbeat(socket_id: String, ref: String)
  // Broadcasting
  Broadcast(
    topic: String,
    event: String,
    payload: json.Json,
    except: Option(String),
  )
  // Heartbeat timeout enforcement
  CheckHeartbeats
}

/// Erlang monotonic time in milliseconds
@external(erlang, "beryl_ffi", "monotonic_time_ms")
fn monotonic_time_ms() -> Int

/// Start the coordinator actor without heartbeat enforcement
pub fn start() -> Result(Subject(Message), StartError) {
  start_with_config(default_config())
}

/// Start the coordinator actor with heartbeat timeout enforcement
pub fn start_with_config(
  config: CoordinatorConfig,
) -> Result(Subject(Message), StartError) {
  case
    config.heartbeat_check_interval_ms > 0 && config.heartbeat_timeout_ms <= 0
  {
    True -> Error(InvalidHeartbeatTimeout)
    False ->
      build_coordinator(config)
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
  case
    config.heartbeat_check_interval_ms > 0 && config.heartbeat_timeout_ms <= 0
  {
    True -> Error(InvalidHeartbeatTimeout)
    False ->
      build_coordinator(config)
      |> actor.named(name)
      |> actor.start
      |> result.map_error(ActorStartFailed)
  }
}

fn build_coordinator(
  config: CoordinatorConfig,
) -> actor.Builder(State, Message, Subject(Message)) {
  let initial_state =
    State(
      handlers: [],
      sockets: dict.new(),
      topics: dict.new(),
      config: config,
      self_subject: None,
    )

  actor.new_with_initialiser(5000, fn(subject) {
    let state = State(..initial_state, self_subject: Some(subject))

    // Schedule the first heartbeat check if configured
    schedule_heartbeat_check(subject, config)

    actor.initialised(state)
    |> actor.returning(subject)
    |> Ok
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
fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    RegisterChannel(pattern, handler, reply) ->
      handle_register_channel(state, pattern, handler, reply)

    SocketConnected(socket_id, send, handler_pid) ->
      handle_socket_connected(state, socket_id, send, handler_pid)

    SocketDisconnected(socket_id) ->
      handle_socket_disconnected(state, socket_id)

    Join(socket_id, topic_name, payload, join_ref, ref) ->
      handle_join(state, socket_id, topic_name, payload, join_ref, ref)

    Leave(socket_id, topic_name, ref) ->
      handle_leave(state, socket_id, topic_name, ref)

    HandleIn(socket_id, topic_name, event, payload, ref) ->
      handle_in(state, socket_id, topic_name, event, payload, ref)

    Heartbeat(socket_id, ref) -> handle_heartbeat(state, socket_id, ref)

    Broadcast(topic_name, event, payload, except) ->
      handle_broadcast(state, topic_name, event, payload, except)

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
  handler_pid: Dynamic,
) -> actor.Next(State, Message) {
  let socket_info =
    SocketInfo(
      id: socket_id,
      send: send,
      handler_pid: handler_pid,
      subscribed_topics: set.new(),
      channel_assigns: dict.new(),
      last_heartbeat: monotonic_time_ms(),
    )

  let log = internal.logger("beryl.coordinator")
  log |> logger.info("Socket connected", [#("socket_id", socket_id)])
  let new_sockets = dict.insert(state.sockets, socket_id, socket_info)
  actor.continue(State(..state, sockets: new_sockets))
}

fn handle_socket_disconnected(
  state: State,
  socket_id: String,
) -> actor.Next(State, Message) {
  let log = internal.logger("beryl.coordinator")
  log |> logger.info("Socket disconnected", [#("socket_id", socket_id)])
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
  case dict.get(state.sockets, socket_id) {
    Error(_) -> actor.continue(state)
    Ok(socket_info) -> {
      case find_handler(state.handlers, topic_name) {
        None -> {
          let reply =
            wire.reply_json(
              join_ref,
              ref,
              topic_name,
              wire.StatusError,
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
              handler_pid: socket_info.handler_pid,
            )

          case handler.join(topic_name, payload, ctx) {
            JoinErrorErased(reason) -> {
              let reply =
                wire.reply_json(
                  join_ref,
                  ref,
                  topic_name,
                  wire.StatusError,
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

              let topic_subscribers =
                dict.get(state.topics, topic_name)
                |> result.unwrap(set.new())
                |> set.insert(socket_id)

              let new_topics =
                dict.insert(state.topics, topic_name, topic_subscribers)
              let new_sockets =
                dict.insert(state.sockets, socket_id, new_socket_info)

              let response = case reply_payload {
                None -> json.object([])
                Some(p) -> p
              }
              let reply =
                wire.reply_json(
                  join_ref,
                  ref,
                  topic_name,
                  wire.StatusOk,
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
        wire.reply_json(None, r, topic_name, wire.StatusOk, json.object([]))
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
                        wire.reply_json(
                          None,
                          r,
                          topic_name,
                          wire.StatusOk,
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
                  let msg = wire.push(topic_name, push_event, push_payload)
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

      let reply = wire.heartbeat_reply(ref)
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

  let log = internal.logger("beryl.coordinator")
  list.each(stale_socket_ids, fn(socket_id) {
    log
    |> logger.warn("Evicting socket due to heartbeat timeout", [
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

  let msg = wire.push(topic_name, event, payload)
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
          let new_topics =
            dict.insert(state.topics, topic_name, topic_subscribers)

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

/// Route a raw wire protocol message to the coordinator.
///
/// Decodes the JSON text and sends the appropriate coordinator message.
/// Silently ignores messages that fail to decode.
pub fn route_message(
  coord: Subject(Message),
  socket_id: String,
  raw_text: String,
) -> Nil {
  case wire.decode_message(raw_text) {
    Error(_) -> {
      let log = internal.logger("beryl.coordinator")
      log
      |> logger.warn("Failed to decode wire protocol message", [
        #("socket_id", socket_id),
      ])
      Nil
    }
    Ok(msg) -> {
      case msg.event {
        "phx_join" -> {
          let ref = option.unwrap(msg.ref, "")
          process.send(
            coord,
            Join(socket_id, msg.topic, msg.payload, msg.join_ref, ref),
          )
        }
        "phx_leave" -> {
          process.send(coord, Leave(socket_id, msg.topic, msg.ref))
        }
        "heartbeat" -> {
          let ref = option.unwrap(msg.ref, "")
          process.send(coord, Heartbeat(socket_id, ref))
        }
        event -> {
          process.send(
            coord,
            HandleIn(socket_id, msg.topic, event, msg.payload, msg.ref),
          )
        }
      }
    }
  }
}
