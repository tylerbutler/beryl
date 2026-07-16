---
title: beryl/socket
description: Socket - Connected client with typed state
---

Socket - Connected client with typed state

 A Socket represents a connected WebSocket client. The `assigns` type
 parameter allows compile-time checking of socket state, ensuring type
 safety when accessing channel-specific data.

 ## Example

 ```gleam
 // Define your channel's assigns type
 pub type RoomAssigns {
   RoomAssigns(user_id: String, room_id: String, joined_at: Int)
 }

 // Socket has compile-time type safety
 fn handle_message(socket: Socket(RoomAssigns)) {
   let assigns = socket.get_assigns(socket)
   io.println("User " <> assigns.user_id <> " in room " <> assigns.room_id)
 }
 ```

## Types

### `Socket`

A connected client socket with typed assigns

 The `assigns` type parameter provides compile-time type safety for
 channel-specific state. Each channel can define its own assigns type,
 and the compiler ensures you only access fields that exist.

```gleam
pub type Socket(a)
```

### `Transport`

Transport abstraction for sending messages

 Wraps the underlying connection (e.g. a Mist WebSocket) with functions to
 send text/binary frames and close the connection.

 `Transport` is opaque; build one with `new_transport`. Its behaviour is
 read through the `@internal` accessors below.

```gleam
pub type Transport
```

### `TransportError`

Errors returned by transport send/close operations.

```gleam
pub type TransportError {
  ConnectionClosed
  SendFailed(String)
}
```

#### Constructors

##### `ConnectionClosed`

The underlying connection is already closed and cannot be used.

##### `SendFailed(String)`

Sending failed; the wrapped `String` describes the reason.

## Functions

### `get_assigns`

Get the current assigns

```gleam
pub fn get_assigns(Socket(a)) -> a
```

### `id`

Get the socket ID

```gleam
pub fn id(Socket(a)) -> String
```

### `map_assigns`

Map assigns to a new type

 Useful when transitioning between channel types or transforming state:

 ```gleam
 let socket = socket.map_assigns(socket, fn(old) {
   NewAssigns(user_id: old.user_id, extra: "data")
 })
 ```

```gleam
pub fn map_assigns(
  Socket(a),
  fn(a) -> b
) -> Socket(b)
```

### `new`

Create a new socket with initial assigns

 Typically called by the WebSocket transport when a connection is established.

```gleam
pub fn new(
  String,
  a,
  Transport
) -> Socket(a)
```

### `new_transport`

Build a transport from its send/close functions.

 - `send_text`: send a UTF-8 text frame to the client.
 - `send_binary`: send a binary frame to the client.
 - `close`: close the underlying connection.

```gleam
pub fn new_transport(
  send_text: fn(String) -> Result(Nil, TransportError),
  send_binary: fn(BitArray) -> Result(Nil, TransportError),
  close: fn() -> Result(Nil, TransportError)
) -> Transport
```

### `set_assigns`

Update the assigns (returns new socket)

 Use this in channel handlers to update socket state:

 ```gleam
 fn handle_in(event, payload, socket) {
   let new_assigns = RoomAssigns(..socket.get_assigns(socket), last_seen: now())
   let socket = socket.set_assigns(socket, new_assigns)
   channel.NoReply(socket)
 }
 ```

```gleam
pub fn set_assigns(
  Socket(a),
  a
) -> Socket(a)
```
