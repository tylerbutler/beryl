//// Beryl - Type-safe real-time communication
////
//// A standalone Gleam library for building real-time applications on the BEAM.
//// Provides WebSocket channels, distributed presence tracking, pub/sub
//// messaging, and channel groups.
////
//// ## Features
////
//// - **Channels** — Topic-based WebSocket messaging with pattern matching
////   (`beryl`, `beryl/channel`, `beryl/coordinator`)
//// - **PubSub** — Distributed publish/subscribe via Erlang `pg`
////   (`beryl/pubsub`)
//// - **Presence** — Distributed presence tracking backed by a causal-context
////   CRDT (add-wins observed-remove set) (`beryl/presence`,
////   `beryl/presence/state`)
//// - **Groups** — Named collections of topics for multi-topic broadcasting
////   (`beryl/group`)
////
//// ## Quick Start
////
//// ```gleam
//// import beryl
//// import beryl/channel
//// import beryl/pubsub
//// import beryl/presence
//// import beryl/group
////
//// pub fn main() {
////   // Optional: start PubSub for distributed messaging
////   let assert Ok(ps) = pubsub.start(pubsub.default_config())
////
////   // Start channels system (with or without PubSub)
////   let config = beryl.default_config() |> beryl.with_pubsub(ps)
////   let assert Ok(channels) = beryl.start(config)
////
////   // Register a channel handler
////   let _ = beryl.register(channels, "room:*", room_channel.new())
////
////   // Start presence tracking
////   let assert Ok(p) = presence.start(presence.default_config("node1"))
////
////   // Start channel groups
////   let assert Ok(groups) = group.start()
////   let assert Ok(Nil) = group.create(groups, "team:eng")
////   let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
////
////   // Broadcast to all topics in a group
////   group.broadcast(groups, channels, "team:eng", "announce", payload)
//// }
//// ```

import beryl/channel.{type Channel}
import beryl/coordinator
import beryl/pubsub.{type PubSub}
import beryl/socket.{type Socket}
import beryl/topic
import beryl/wire
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}

// Re-export types from coordinator for convenience
pub type ChannelHandler =
  coordinator.ChannelHandler

pub type RegisterError =
  coordinator.RegisterError

/// Configuration for the channels system
pub type Config {
  Config(
    /// Heartbeat interval in milliseconds (default: 30000)
    heartbeat_interval_ms: Int,
    /// Heartbeat timeout - disconnect if no response (default: 60000)
    heartbeat_timeout_ms: Int,
    /// Max connections per IP (0 = unlimited)
    max_connections_per_ip: Int,
    /// Optional PubSub for distributed broadcasts across nodes
    pubsub: Option(PubSub),
  )
}

/// Default configuration
pub fn default_config() -> Config {
  Config(
    heartbeat_interval_ms: 30_000,
    heartbeat_timeout_ms: 60_000,
    max_connections_per_ip: 0,
    pubsub: None,
  )
}

/// Add PubSub to a configuration for distributed broadcasts
pub fn with_pubsub(config: Config, ps: PubSub) -> Config {
  Config(..config, pubsub: Some(ps))
}

/// Channels system handle
///
/// This is the main entry point for interacting with the channels system.
/// Pass this to channel handlers and the WebSocket transport.
pub type Channels {
  Channels(
    /// The coordinator actor subject - pass to transport.websocket.upgrade()
    coordinator: Subject(coordinator.Message),
    /// Configuration
    config: Config,
    /// Optional PubSub for distributed messaging
    pubsub: Option(PubSub),
  )
}

/// Errors when starting channels
pub type StartError {
  CoordinatorStartFailed
}

/// Start the channels system
///
/// Call once at application startup. Returns a handle that can be passed
/// to the WebSocket transport and used for broadcasting.
///
/// ## Example
///
/// ```gleam
/// pub fn main() {
///   let assert Ok(channels) = beryl.start(beryl.default_config())
///   // Use channels...
/// }
/// ```
pub fn start(config: Config) -> Result(Channels, StartError) {
  // Server checks at half the timeout interval to detect stale sockets
  // promptly. The client heartbeat_interval_ms is informational only
  // (used by clients to know how often to send heartbeats).
  let check_interval = config.heartbeat_timeout_ms / 2
  let coord_config =
    coordinator.CoordinatorConfig(
      heartbeat_check_interval_ms: check_interval,
      heartbeat_timeout_ms: config.heartbeat_timeout_ms,
    )

  case coordinator.start_with_config(coord_config) {
    Error(_) -> Error(CoordinatorStartFailed)
    Ok(coord) ->
      Ok(Channels(coordinator: coord, config: config, pubsub: config.pubsub))
  }
}

/// Register a channel handler for a topic pattern
///
/// Patterns can be exact matches like "room:lobby" or wildcards like "room:*"
/// which matches any topic starting with "room:".
///
/// ## Example
///
/// ```gleam
/// // Create a typed channel
/// let chat_channel = channel.new(fn(topic, payload, socket) {
///   // Handle join
///   channel.JoinOk(reply: None, socket: socket)
/// })
/// |> channel.with_handle_in(fn(event, payload, socket) {
///   // Handle incoming messages
///   channel.NoReply(socket)
/// })
///
/// // Register it
/// beryl.register(channels, "chat:*", chat_channel)
/// ```
pub fn register(
  channels: Channels,
  pattern: String,
  handler: Channel(assigns, info),
) -> Result(Nil, RegisterError) {
  // Convert typed Channel to type-erased ChannelHandler
  let erased_handler = erase_channel_types(pattern, handler)

  // Register with coordinator
  process.call(channels.coordinator, 5000, fn(reply) {
    coordinator.RegisterChannel(pattern, erased_handler, reply)
  })
}

/// Broadcast a message to all subscribers of a topic
///
/// This sends the message to all sockets subscribed to the topic.
///
/// ## Example
///
/// ```gleam
/// beryl.broadcast(
///   channels,
///   "room:lobby",
///   "new_message",
///   json.object([#("text", json.string("Hello!"))]),
/// )
/// ```
pub fn broadcast(
  channels: Channels,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  // Local broadcast via coordinator
  process.send(
    channels.coordinator,
    coordinator.Broadcast(topic_name, event, payload, None),
  )
  // Distributed broadcast via PubSub (if configured)
  case channels.pubsub {
    Some(ps) -> pubsub.broadcast(ps, topic_name, event, payload)
    None -> Nil
  }
}

/// Broadcast a message to all subscribers except one socket
///
/// Useful for broadcasting a message to everyone except the sender.
///
/// ## Example
///
/// ```gleam
/// // In a channel handler, broadcast to others
/// beryl.broadcast_from(
///   channels,
///   socket_id,
///   "room:lobby",
///   "user_typing",
///   json.object([#("user", json.string("alice"))]),
/// )
/// ```
pub fn broadcast_from(
  channels: Channels,
  except_socket_id: String,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  // Local broadcast via coordinator (excluding sender)
  process.send(
    channels.coordinator,
    coordinator.Broadcast(topic_name, event, payload, Some(except_socket_id)),
  )
  // Distributed broadcast via PubSub (if configured)
  // Note: PubSub broadcast_from excludes by pid, not socket_id.
  // For cross-node, we broadcast to all since the sender is on a different node.
  case channels.pubsub {
    Some(ps) -> pubsub.broadcast(ps, topic_name, event, payload)
    None -> Nil
  }
}

/// Push a message to a specific socket via its context
///
/// Note: In the lean MVP, this uses the send function from SocketContext.
/// The message is sent directly, not through the coordinator.
pub fn push_to_socket(
  ctx: coordinator.SocketContext,
  event: String,
  payload: json.Json,
) -> Nil {
  let msg =
    json.to_string(
      json.preprocessed_array([
        json.null(),
        json.null(),
        json.string(ctx.topic),
        json.string(event),
        payload,
      ]),
    )
  let _ = ctx.send(msg)
  Nil
}

/// Get the topic ID from a topic using wildcard extraction
///
/// For pattern "room:*" and topic "room:lobby", returns Ok("lobby")
///
/// ## Example
///
/// ```gleam
/// let assert Ok("lobby") = topic.extract_id(topic.Wildcard("room:"), "room:lobby")
/// ```
pub fn extract_topic_id(
  pattern: topic.TopicPattern,
  topic_name: String,
) -> Result(String, Nil) {
  topic.extract_id(pattern, topic_name)
}

// ─────────────────────────────────────────────────────────────────────────────
// Type erasure - Convert typed Channel to ChannelHandler
// ─────────────────────────────────────────────────────────────────────────────

/// Convert a typed Channel to a type-erased ChannelHandler
///
/// This is necessary because we need to store handlers for different
/// channel types in the same registry.
fn erase_channel_types(
  pattern_str: String,
  typed_channel: Channel(assigns, info),
) -> ChannelHandler {
  let pattern = topic.parse_pattern(pattern_str)

  coordinator.ChannelHandler(
    pattern: pattern,
    join: fn(
      topic_name: String,
      payload: Dynamic,
      ctx: coordinator.SocketContext,
    ) {
      // Create a typed socket with Nil assigns (will be set by join)
      let typed_socket = create_socket_from_context(ctx)

      // Decode Dynamic payload to Json for the handler
      let json_payload = wire.dynamic_to_json(payload)

      // Call the typed join handler (unsafe coerce socket to expected type)
      case
        typed_channel.join(
          topic_name,
          json_payload,
          unsafe_coerce_socket(typed_socket),
        )
      {
        channel.JoinOk(reply, new_socket) -> {
          // Extract assigns and type-erase them
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.JoinOkErased(reply: reply, assigns: erased_assigns)
        }
        channel.JoinError(reason) -> {
          coordinator.JoinErrorErased(reason: reason)
        }
      }
    },
    handle_in: fn(
      event: String,
      payload: Dynamic,
      ctx: coordinator.SocketContext,
    ) {
      // Reconstruct typed socket with current assigns
      let typed_socket = create_socket_with_assigns(ctx)

      // Decode Dynamic payload to Json for the handler
      let json_payload = wire.dynamic_to_json(payload)

      // Call the typed handle_in handler (unsafe coerce socket to expected type)
      case
        typed_channel.handle_in(
          event,
          json_payload,
          unsafe_coerce_socket(typed_socket),
        )
      {
        channel.NoReply(new_socket) -> {
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.NoReplyErased(assigns: erased_assigns)
        }
        channel.Reply(reply_event, reply_payload, new_socket) -> {
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.ReplyErased(
            event: reply_event,
            payload: reply_payload,
            assigns: erased_assigns,
          )
        }
        channel.Push(push_event, push_payload, new_socket) -> {
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.PushErased(
            event: push_event,
            payload: push_payload,
            assigns: erased_assigns,
          )
        }
        channel.Stop(reason) -> {
          coordinator.StopErased(reason: reason)
        }
      }
    },
    terminate: fn(reason: channel.StopReason, ctx: coordinator.SocketContext) {
      let typed_socket = create_socket_with_assigns(ctx)
      // Unsafe coerce socket to expected type
      typed_channel.terminate(reason, unsafe_coerce_socket(typed_socket))
    },
  )
}

/// Create a socket from context with Nil assigns (for join)
fn create_socket_from_context(ctx: coordinator.SocketContext) -> Socket(Nil) {
  let transport =
    socket.Transport(
      send_text: fn(text) {
        ctx.send(text)
        |> result_to_transport_result()
      },
      send_binary: fn(_) { Error(socket.SendFailed("Binary not supported")) },
      close: fn() { Ok(Nil) },
    )

  socket.new(ctx.socket_id, Nil, transport)
}

/// Create a socket from context with existing assigns (type-erased)
fn create_socket_with_assigns(ctx: coordinator.SocketContext) -> Socket(Dynamic) {
  let transport =
    socket.Transport(
      send_text: fn(text) {
        ctx.send(text)
        |> result_to_transport_result()
      },
      send_binary: fn(_) { Error(socket.SendFailed("Binary not supported")) },
      close: fn() { Ok(Nil) },
    )

  socket.new(ctx.socket_id, ctx.assigns, transport)
}

fn result_to_transport_result(
  result: Result(Nil, Nil),
) -> Result(Nil, socket.TransportError) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(socket.SendFailed("Send failed"))
  }
}

/// Unsafe coercion to Dynamic - only use for type erasure
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_to_dynamic(value: a) -> Dynamic

/// Unsafe coercion of socket types - only use for type erasure
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_socket(socket: Socket(a)) -> Socket(b)
