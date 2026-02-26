//// Channel - Topic-based message handlers
////
//// Channels handle real-time communication for topic patterns. Each channel
//// defines how to handle joins, incoming messages, and cleanup.
////
//// ## Example
////
//// ```gleam
//// pub type RoomAssigns {
////   RoomAssigns(user_id: String, room_id: String)
//// }
////
//// pub fn new() -> Channel(RoomAssigns, Nil) {
////   channel.new(join)
////   |> channel.with_handle_in(handle_in)
////   |> channel.with_terminate(terminate)
//// }
////
//// fn join(topic, payload, socket) {
////   let assigns = RoomAssigns(user_id: "...", room_id: "...")
////   channel.JoinOk(reply: None, socket: socket.set_assigns(socket, assigns))
//// }
//// ```

import beryl/socket.{type Socket}
import gleam/json.{type Json}
import gleam/option.{type Option}

/// Result of joining a channel
pub type JoinResult(assigns) {
  /// Join succeeded, optionally send a reply payload
  JoinOk(reply: Option(Json), socket: Socket(assigns))
  /// Join failed with error payload
  JoinError(reason: Json)
}

/// Result of handling an incoming message
pub type HandleResult(assigns) {
  /// Continue without sending a reply
  NoReply(socket: Socket(assigns))
  /// Send a reply to the client (in response to their message)
  Reply(event: String, payload: Json, socket: Socket(assigns))
  /// Push a message to the client (server-initiated)
  Push(event: String, payload: Json, socket: Socket(assigns))
  /// Stop the channel with a reason
  Stop(reason: StopReason)
}

/// Why a channel is stopping
pub type StopReason {
  /// Normal shutdown (client left or disconnected cleanly)
  Normal
  /// Server-initiated shutdown
  Shutdown
  /// Client failed to send heartbeat within the configured timeout
  HeartbeatTimeout
  /// Error occurred
  Error(String)
}

/// Channel behavior definition
///
/// Type parameters:
/// - `assigns`: Socket state type for this channel
/// - `info`: Type of messages from other processes (via handle_info)
pub type Channel(assigns, info) {
  Channel(
    /// Called when a client attempts to join a topic
    ///
    /// Return JoinOk to accept the connection (with optional reply payload),
    /// or JoinError to reject it.
    join: fn(String, Json, Socket(assigns)) -> JoinResult(assigns),
    /// Called when a client sends a message to this channel
    ///
    /// The event string identifies the message type (e.g., "new_message", "typing").
    handle_in: fn(String, Json, Socket(assigns)) -> HandleResult(assigns),
    /// Called when this socket receives a message from another process
    ///
    /// Use this for server-initiated pushes, background job results, etc.
    handle_info: fn(info, Socket(assigns)) -> HandleResult(assigns),
    /// Called when the client leaves or disconnects
    ///
    /// Use for cleanup (presence, database updates, etc.)
    terminate: fn(StopReason, Socket(assigns)) -> Nil,
  )
}

/// Create a new channel with just a join handler.
///
/// Other handlers can be added using the `with_*` functions.
pub fn new(
  join: fn(String, Json, Socket(assigns)) -> JoinResult(assigns),
) -> Channel(assigns, info) {
  Channel(
    join: join,
    handle_in: fn(_, _, socket) { NoReply(socket) },
    handle_info: fn(_, socket) { NoReply(socket) },
    terminate: fn(_, _) { Nil },
  )
}

/// Add an incoming message handler
pub fn with_handle_in(
  channel: Channel(assigns, info),
  handler: fn(String, Json, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns, info) {
  Channel(..channel, handle_in: handler)
}

/// Add an info message handler (for server-to-socket messages)
pub fn with_handle_info(
  channel: Channel(assigns, info),
  handler: fn(info, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns, info) {
  Channel(..channel, handle_info: handler)
}

/// Add a terminate handler for cleanup
pub fn with_terminate(
  channel: Channel(assigns, info),
  handler: fn(StopReason, Socket(assigns)) -> Nil,
) -> Channel(assigns, info) {
  Channel(..channel, terminate: handler)
}

/// Create a simple error response
pub fn error(message: String) -> Json {
  json.object([#("error", json.string(message))])
}

/// Create an error response with code
pub fn error_with_code(code: Int, message: String) -> Json {
  json.object([#("code", json.int(code)), #("error", json.string(message))])
}
