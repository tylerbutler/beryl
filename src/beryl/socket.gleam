//// Socket - Connected client with typed state
////
//// A Socket represents a connected WebSocket client. The `assigns` type
//// parameter allows compile-time checking of socket state, ensuring type
//// safety when accessing channel-specific data.
////
//// ## Example
////
//// ```gleam
//// // Define your channel's assigns type
//// pub type RoomAssigns {
////   RoomAssigns(user_id: String, room_id: String, joined_at: Int)
//// }
////
//// // Socket has compile-time type safety
//// fn handle_message(socket: Socket(RoomAssigns)) {
////   let assigns = socket.get_assigns(socket)
////   io.println("User " <> assigns.user_id <> " in room " <> assigns.room_id)
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}

/// Transport abstraction for sending messages
pub type Transport {
  Transport(
    send_text: fn(String) -> Result(Nil, TransportError),
    send_binary: fn(BitArray) -> Result(Nil, TransportError),
    close: fn() -> Result(Nil, TransportError),
  )
}

pub type TransportError {
  ConnectionClosed
  SendFailed(String)
}

/// A connected client socket with typed assigns
///
/// The `assigns` type parameter provides compile-time type safety for
/// channel-specific state. Each channel can define its own assigns type,
/// and the compiler ensures you only access fields that exist.
pub opaque type Socket(assigns) {
  Socket(
    id: String,
    assigns: assigns,
    transport: Transport,
    metadata: Dict(String, Dynamic),
  )
}

/// Create a new socket with initial assigns
///
/// Typically called by the WebSocket transport when a connection is established.
pub fn new(
  id: String,
  assigns: assigns,
  transport: Transport,
) -> Socket(assigns) {
  Socket(id: id, assigns: assigns, transport: transport, metadata: dict.new())
}

/// Get the socket ID
pub fn id(socket: Socket(assigns)) -> String {
  socket.id
}

/// Get the current assigns
pub fn get_assigns(socket: Socket(assigns)) -> assigns {
  socket.assigns
}

/// Update the assigns (returns new socket)
///
/// Use this in channel handlers to update socket state:
///
/// ```gleam
/// fn handle_in(event, payload, socket) {
///   let new_assigns = RoomAssigns(..socket.get_assigns(socket), last_seen: now())
///   let socket = socket.set_assigns(socket, new_assigns)
///   channel.NoReply(socket)
/// }
/// ```
pub fn set_assigns(socket: Socket(a), assigns: a) -> Socket(a) {
  Socket(..socket, assigns: assigns)
}

/// Map assigns to a new type
///
/// Useful when transitioning between channel types or transforming state:
///
/// ```gleam
/// let socket = socket.map_assigns(socket, fn(old) {
///   NewAssigns(user_id: old.user_id, extra: "data")
/// })
/// ```
pub fn map_assigns(socket: Socket(a), f: fn(a) -> b) -> Socket(b) {
  Socket(
    id: socket.id,
    assigns: f(socket.assigns),
    transport: socket.transport,
    metadata: socket.metadata,
  )
}

/// Get the transport for sending messages
@internal
pub fn transport(socket: Socket(assigns)) -> Transport {
  socket.transport
}

/// Set arbitrary metadata (for framework use)
@internal
pub fn set_metadata(
  socket: Socket(assigns),
  key: String,
  value: Dynamic,
) -> Socket(assigns) {
  Socket(..socket, metadata: dict.insert(socket.metadata, key, value))
}

/// Get metadata value
@internal
pub fn get_metadata(
  socket: Socket(assigns),
  key: String,
) -> Result(Dynamic, Nil) {
  dict.get(socket.metadata, key)
}
