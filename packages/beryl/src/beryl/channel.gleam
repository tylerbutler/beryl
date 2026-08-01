//// Channel - Topic-based message callbacks
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
//// pub fn new() -> Channel(RoomAssigns, info) {
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
  /// Send a successful reply to the client in response to their message.
  ///
  /// When returned from `handle_in`, this is encoded as a Phoenix `phx_reply`
  /// with `"status": "ok"`, tied to the original client ref — the `event`
  /// field is ignored by the coordinator. When returned from `handle_info`
  /// (where no client ref exists), it is sent as a push using `event` as the
  /// event name.
  ///
  /// The status is always `"ok"`: `Reply("error", payload, socket)` reaches
  /// the client's `push.receive("ok", ...)` hook, not `receive("error", ...)`.
  /// Use `ReplyError` to signal failure.
  Reply(event: String, payload: Json, socket: Socket(assigns))
  /// Send an error reply to the client in response to their message
  /// (`"status": "error"` in Phoenix framing, delivered to the client's
  /// `push.receive("error", ...)` hook).
  ///
  /// Only meaningful from `handle_in` for messages carrying a client ref;
  /// from `handle_info`/`handle_binary` (where no ref exists) the reply is
  /// dropped with a warning.
  ReplyError(payload: Json, socket: Socket(assigns))
  /// Push a message to the client (server-initiated)
  Push(event: String, payload: Json, socket: Socket(assigns))
  /// Stop the channel with a reason
  Stop(reason: StopReason)
}

/// Why a channel is stopping.
///
/// Delivered to every channel's `terminate` callback. Match with a catch-all
/// (`_`) arm: new stop reasons may be added in minor releases.
pub type StopReason {
  /// Normal shutdown (client left or disconnected cleanly)
  Normal
  /// Server-initiated shutdown
  Shutdown
  /// Client failed to send heartbeat within the configured timeout
  HeartbeatTimeout
  /// The channel stopped because of an error (named `Errored` so importing
  /// it unqualified does not shadow the prelude's `Result` `Error`
  /// constructor)
  Errored(String)
}

/// Channel behavior definition
///
/// Type parameters:
/// - `assigns`: Socket state type for this channel
/// - `info`: Server-originated/internal message type delivered to `handle_info`
///   (see `beryl.send_info`). Channels that do not use `handle_info` leave this
///   parameter generic.
pub opaque type Channel(assigns, info) {
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
    /// Called when an OTP process sends a server-originated message to this
    /// channel.
    ///
    /// The message is the typed `info` value passed to `beryl.send_info` — no
    /// `Dynamic` and no unsafe cast are required in application code.
    handle_info: fn(info, Socket(assigns)) -> HandleResult(assigns),
    /// Called when the client leaves or disconnects
    ///
    /// Use for cleanup (presence, database updates, etc.)
    terminate: fn(StopReason, Socket(assigns)) -> Nil,
  )
}

// nolint: unused_exports -- package-internal accessor used by beryl's type-erasure layer; hidden from public docs with @internal
@internal
pub fn join_callback(
  channel: Channel(assigns, info),
) -> fn(String, Dynamic, Socket(assigns)) -> JoinResult(assigns) {
  channel.join
}

// nolint: unused_exports -- package-internal accessor used by beryl's type-erasure layer; hidden from public docs with @internal
@internal
pub fn handle_in_callback(
  channel: Channel(assigns, info),
) -> fn(String, Dynamic, Socket(assigns)) -> HandleResult(assigns) {
  channel.handle_in
}

// nolint: unused_exports -- package-internal accessor used by beryl's type-erasure layer; hidden from public docs with @internal
@internal
pub fn handle_binary_callback(
  channel: Channel(assigns, info),
) -> fn(BitArray, Socket(assigns)) -> HandleResult(assigns) {
  channel.handle_binary
}

// nolint: unused_exports -- package-internal accessor used by beryl's type-erasure layer; hidden from public docs with @internal
@internal
pub fn handle_info_callback(
  channel: Channel(assigns, info),
) -> fn(info, Socket(assigns)) -> HandleResult(assigns) {
  channel.handle_info
}

// nolint: unused_exports -- package-internal accessor used by beryl's type-erasure layer; hidden from public docs with @internal
@internal
pub fn terminate_callback(
  channel: Channel(assigns, info),
) -> fn(StopReason, Socket(assigns)) -> Nil {
  channel.terminate
}

/// Create a new channel with just a join callback.
///
/// Other callbacks can be added using the `with_*` functions.
pub fn new(
  join: fn(String, Dynamic, Socket(assigns)) -> JoinResult(assigns),
) -> Channel(assigns, info) {
  Channel(
    join: join,
    handle_in: fn(_, _, socket) { NoReply(socket) },
    handle_binary: fn(_, socket) { NoReply(socket) },
    handle_info: fn(_, socket) { NoReply(socket) },
    terminate: fn(_, _) { Nil },
  )
}

/// Add an incoming message callback
pub fn with_handle_in(
  channel: Channel(assigns, info),
  handler: fn(String, Dynamic, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns, info) {
  Channel(..channel, handle_in: handler)
}

/// Decode an inbound channel payload into an application type.
pub fn decode_payload(
  payload: Dynamic,
  decoder: decode.Decoder(a),
) -> Result(a, List(decode.DecodeError)) {
  decode.run(payload, decoder)
}

/// Add a binary message callback
pub fn with_handle_binary(
  channel: Channel(assigns, info),
  handler: fn(BitArray, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns, info) {
  Channel(..channel, handle_binary: handler)
}

/// Add a server-originated OTP message callback.
///
/// The callback receives the typed `info` value sent via `beryl.send_info`.
/// `Reply` results are sent as pushes because server-originated messages do not
/// have a client message ref to reply to.
pub fn with_handle_info(
  channel: Channel(assigns, info),
  handler: fn(info, Socket(assigns)) -> HandleResult(assigns),
) -> Channel(assigns, info) {
  Channel(..channel, handle_info: handler)
}

/// Add a terminate callback for cleanup
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

// nolint: unused_exports -- public API helper for library consumers (examples/chatrooms)
/// Create an error response with code
pub fn error_with_code(code: Int, message: String) -> Json {
  json.object([#("code", json.int(code)), #("error", json.string(message))])
}
