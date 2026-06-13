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
//// pub fn new() -> Channel(RoomAssigns) {
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
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
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
  /// Send a reply to the client in response to their message.
  ///
  /// When returned from `handle_in`, this is encoded as a Phoenix `phx_reply`
  /// tied to the original client ref — the `event` field is ignored by the
  /// coordinator. When returned from `handle_info` (where no client ref
  /// exists), it is sent as a push using `event` as the event name.
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
pub type Channel(assigns) {
  Channel(
    /// Called when a client attempts to join a topic
    ///
    /// Return JoinOk to accept the connection (with optional reply payload),
    /// or JoinError to reject it.
    join: fn(String, Dynamic, Socket(assigns)) -> JoinResult(assigns),
    /// Called when a client sends a text message to this channel
    ///
    /// The event string identifies the message type (e.g., "new_message", "typing").
    handle_in: fn(String, Dynamic, Socket(assigns)) -> HandleResult(assigns),
    /// Called when a client sends a binary frame to this channel
    ///
    /// Binary frames are passed as raw BitArray when the configured codec has
    /// no binary decoder.
    handle_binary: fn(BitArray, Socket(assigns)) -> HandleResult(assigns),
    /// Called when an OTP process sends a server-originated message to this channel
    handle_info: fn(Dynamic, Socket(assigns)) -> HandleResult(assigns),
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
  join: fn(String, Dynamic, Socket(assigns)) -> JoinResult(assigns),
) -> Channel(assigns) {
  Channel(
    join: join,
    handle_in: fn(_, _, socket) { NoReply(socket) },
    handle_binary: fn(_, socket) { NoReply(socket) },
    handle_info: fn(_, socket) { NoReply(socket) },
    terminate: fn(_, _) { Nil },
  )
}

/// Add an incoming message handler
pub fn with_handle_in(
  channel: Channel(assigns),
  handler: fn(String, Dynamic, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns) {
  Channel(..channel, handle_in: handler)
}

/// Decode an inbound channel payload into an application type.
pub fn decode_payload(
  payload: Dynamic,
  decoder: decode.Decoder(a),
) -> Result(a, List(decode.DecodeError)) {
  decode.run(payload, decoder)
}

/// Add a binary message handler
pub fn with_handle_binary(
  channel: Channel(assigns),
  handler: fn(BitArray, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns) {
  Channel(..channel, handle_binary: handler)
}

/// Add a server-originated OTP message handler.
///
/// `Reply` results are sent as pushes because server-originated messages do not
/// have a client message ref to reply to.
pub fn with_handle_info(
  channel: Channel(assigns),
  handler: fn(Dynamic, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns) {
  Channel(..channel, handle_info: handler)
}

/// Add a terminate handler for cleanup
pub fn with_terminate(
  channel: Channel(assigns),
  handler: fn(StopReason, Socket(assigns)) -> Nil,
) -> Channel(assigns) {
  Channel(..channel, terminate: handler)
}

// nolint: unused_exports -- public API helper for library consumers (examples/chatrooms)
/// Create a simple error response
pub fn error(message: String) -> Json {
  json.object([#("error", json.string(message))])
}

// nolint: unused_exports -- public API helper for library consumers (examples/chatrooms)
/// Create an error response with code
pub fn error_with_code(code: Int, message: String) -> Json {
  json.object([#("code", json.int(code)), #("error", json.string(message))])
}
