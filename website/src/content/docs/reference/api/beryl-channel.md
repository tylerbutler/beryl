---
title: beryl/channel
description: Channel - Topic-based message handlers
---

Channel - Topic-based message handlers

 Channels handle real-time communication for topic patterns. Each channel
 defines how to handle joins, incoming messages, and cleanup.

 ## Example

 ```gleam
 pub type RoomAssigns {
   RoomAssigns(user_id: String, room_id: String)
 }

 pub fn new() -> Channel(RoomAssigns, info) {
   channel.new(join)
   |> channel.with_handle_in(handle_in)
   |> channel.with_terminate(terminate)
 }

 fn join(topic, payload, socket) {
   let assigns = RoomAssigns(user_id: "...", room_id: "...")
   channel.JoinOk(reply: None, socket: socket.set_assigns(socket, assigns))
 }
 ```

## Types

### `Channel`

Channel behavior definition

 Type parameters:
 - `assigns`: Socket state type for this channel
 - `info`: Server-originated/internal message type delivered to `handle_info`
   (see `beryl.send_info`). Channels that do not use `handle_info` leave this
   parameter generic.

```gleam
pub type Channel(a, b) {
  Channel(
    join: fn(String, dynamic.Dynamic, socket.Socket(a)) -> JoinResult(a),
    handle_in: fn(String, dynamic.Dynamic, socket.Socket(a)) -> HandleResult(a),
    handle_binary: fn(BitArray, socket.Socket(a)) -> HandleResult(a),
    handle_info: fn(b, socket.Socket(a)) -> HandleResult(a),
    terminate: fn(StopReason, socket.Socket(a)) -> Nil
  )
}
```

### `HandleResult`

Result of handling an incoming message

```gleam
pub type HandleResult(a) {
  NoReply(socket: socket.Socket(a))
  Reply(
    event: String,
    payload: json.Json,
    socket: socket.Socket(a)
  )
  Push(
    event: String,
    payload: json.Json,
    socket: socket.Socket(a)
  )
  Stop(reason: StopReason)
}
```

#### Constructors

##### `NoReply(socket: socket.Socket(a))`

Continue without sending a reply

##### `Reply(
  event: String,
  payload: json.Json,
  socket: socket.Socket(a)
)`

Send a reply to the client in response to their message.

 When returned from `handle_in`, this is encoded as a Phoenix `phx_reply`
 tied to the original client ref — the `event` field is ignored by the
 coordinator. When returned from `handle_info` (where no client ref
 exists), it is sent as a push using `event` as the event name.

##### `Push(
  event: String,
  payload: json.Json,
  socket: socket.Socket(a)
)`

Push a message to the client (server-initiated)

##### `Stop(reason: StopReason)`

Stop the channel with a reason

### `JoinResult`

Result of joining a channel

```gleam
pub type JoinResult(a) {
  JoinOk(
    reply: option.Option(json.Json),
    socket: socket.Socket(a)
  )
  JoinError(reason: json.Json)
}
```

#### Constructors

##### `JoinOk(
  reply: option.Option(json.Json),
  socket: socket.Socket(a)
)`

Join succeeded, optionally send a reply payload

##### `JoinError(reason: json.Json)`

Join failed with error payload

### `StopReason`

Why a channel is stopping

```gleam
pub type StopReason {
  Normal
  Shutdown
  HeartbeatTimeout
  Error(String)
}
```

#### Constructors

##### `Normal`

Normal shutdown (client left or disconnected cleanly)

##### `Shutdown`

Server-initiated shutdown

##### `HeartbeatTimeout`

Client failed to send heartbeat within the configured timeout

##### `Error(String)`

Error occurred

## Functions

### `decode_payload`

Decode an inbound channel payload into an application type.

```gleam
pub fn decode_payload(
  dynamic.Dynamic,
  decode.Decoder(a)
) -> Result(a, List(decode.DecodeError))
```

### `error`

Create a simple error response

```gleam
pub fn error(String) -> json.Json
```

### `error_with_code`

Create an error response with code

```gleam
pub fn error_with_code(
  Int,
  String
) -> json.Json
```

### `new`

Create a new channel with just a join handler.

 Other handlers can be added using the `with_*` functions.

```gleam
pub fn new(fn(String, dynamic.Dynamic, socket.Socket(a)) -> JoinResult(a)) -> Channel(a, b)
```

### `with_handle_binary`

Add a binary message handler

```gleam
pub fn with_handle_binary(
  Channel(a, b),
  fn(BitArray, socket.Socket(a)) -> HandleResult(a)
) -> Channel(a, b)
```

### `with_handle_in`

Add an incoming message handler

```gleam
pub fn with_handle_in(
  Channel(a, b),
  fn(String, dynamic.Dynamic, socket.Socket(a)) -> HandleResult(a)
) -> Channel(a, b)
```

### `with_handle_info`

Add a server-originated OTP message handler.

 The handler receives the typed `info` value sent via `beryl.send_info`.
 `Reply` results are sent as pushes because server-originated messages do not
 have a client message ref to reply to.

```gleam
pub fn with_handle_info(
  Channel(a, b),
  fn(b, socket.Socket(a)) -> HandleResult(a)
) -> Channel(a, b)
```

### `with_terminate`

Add a terminate handler for cleanup

```gleam
pub fn with_terminate(
  Channel(a, b),
  fn(StopReason, socket.Socket(a)) -> Nil
) -> Channel(a, b)
```
