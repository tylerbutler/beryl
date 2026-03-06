---
title: Channels
---

Channels are the core abstraction in beryl. A channel maps a topic pattern to a set of typed callback functions that handle joins, messages, and cleanup.

## Topics and patterns

Topics are colon-delimited string identifiers. Patterns can be exact matches or use a trailing wildcard:

```gleam
import beryl/topic

// Exact: only matches "room:lobby"
topic.parse_pattern("room:lobby")  // -> Exact("room:lobby")

// Wildcard: matches "room:lobby", "room:123", etc.
topic.parse_pattern("room:*")  // -> Wildcard("room:")

// Extract the dynamic part
topic.extract_id(Wildcard("room:"), "room:lobby")  // -> Ok("lobby")

// Parse topic segments
topic.segments("room:lobby")  // -> ["room", "lobby"]
topic.namespace("room:lobby")  // -> Ok("room")
```

## Defining a channel

Channels are built using a builder pattern starting with `channel.new()`:

```gleam
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

/// Typed assigns — compile-time checked socket state
pub type RoomAssigns {
  RoomAssigns(user_id: String, room_id: String)
}

pub fn new() -> Channel(RoomAssigns) {
  channel.new(join)
  |> channel.with_handle_in(handle_in)
  |> channel.with_handle_binary(handle_binary)
  |> channel.with_terminate(terminate)
}
```

### Join callback

Called when a client sends a `phx_join` message. Return `JoinOk` to accept or `JoinError` to reject:

```gleam
fn join(
  topic: String,
  payload: Json,
  socket: Socket(RoomAssigns),
) -> JoinResult(RoomAssigns) {
  // Extract room ID from topic pattern
  let assert Ok(room_id) =
    topic.extract_id(topic.Wildcard("room:"), topic)

  let assigns = RoomAssigns(user_id: "user_123", room_id: room_id)
  let socket = socket.set_assigns(socket, assigns)

  // Optionally send a reply payload
  let reply = json.object([#("status", json.string("joined"))])
  channel.JoinOk(reply: Some(reply), socket: socket)
}
```

### Message handler

Called for each incoming text message. The `event` string identifies the message type:

```gleam
fn handle_in(
  event: String,
  payload: Json,
  socket: Socket(RoomAssigns),
) -> HandleResult(RoomAssigns) {
  case event {
    "new_message" -> {
      // Reply to the sender
      channel.Reply("new_message", payload, socket)
    }
    "typing" -> {
      // No reply needed
      channel.NoReply(socket)
    }
    "update_status" -> {
      // Push a server-initiated message
      let response = json.object([#("updated", json.bool(True))])
      channel.Push("status_changed", response, socket)
    }
    _ -> channel.NoReply(socket)
  }
}
```

### Handle results

Channel handlers return one of these results:

| Result | Description |
|--------|-------------|
| `NoReply(socket)` | Continue without sending anything |
| `Reply(event, payload, socket)` | Send a reply to the client's message ref |
| `Push(event, payload, socket)` | Send a server-initiated message (no ref) |
| `Stop(reason)` | Terminate the channel |

### Binary handler

Handle raw binary WebSocket frames (bypasses the wire protocol):

```gleam
fn handle_binary(
  data: BitArray,
  socket: Socket(RoomAssigns),
) -> HandleResult(RoomAssigns) {
  // Process binary data (e.g., file uploads, audio chunks)
  channel.NoReply(socket)
}
```

### Terminate callback

Called when a client leaves or disconnects. Use for cleanup:

```gleam
fn terminate(
  reason: channel.StopReason,
  socket: Socket(RoomAssigns),
) -> Nil {
  case reason {
    channel.Normal -> Nil           // Clean disconnect
    channel.Shutdown -> Nil         // Server-initiated
    channel.HeartbeatTimeout -> Nil // Client went silent
    channel.Error(msg) -> Nil       // Something went wrong
  }
}
```

## Registering channels

Register channels with the beryl system using topic patterns:

```gleam
import beryl

let assert Ok(channels) = beryl.start(beryl.default_config())

// Register handlers for different topic patterns
let assert Ok(Nil) = beryl.register(channels, "room:*", room_channel.new())
let assert Ok(Nil) = beryl.register(channels, "user:*", user_channel.new())
let assert Ok(Nil) = beryl.register(channels, "system", system_channel.new())
```

## Broadcasting

Send messages to all subscribers of a topic:

```gleam
// Broadcast to everyone on a topic
beryl.broadcast(
  channels,
  "room:lobby",
  "new_message",
  json.object([#("text", json.string("Hello!"))]),
)

// Broadcast to everyone except one socket
beryl.broadcast_from(
  channels,
  socket_id,
  "room:lobby",
  "user_typing",
  json.object([#("user", json.string("alice"))]),
)
```

## Socket state

Sockets carry typed assigns that persist across messages:

```gleam
import beryl/socket

// Get current assigns
let assigns = socket.get_assigns(socket)

// Update assigns (returns new socket)
let socket = socket.set_assigns(socket, RoomAssigns(..assigns, room_id: "new"))

// Transform assigns to a different type
let socket = socket.map_assigns(socket, fn(old) {
  NewType(user_id: old.user_id)
})
```
