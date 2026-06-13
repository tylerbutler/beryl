---
title: Channels
---

Channels are the core abstraction in beryl. A channel maps a topic pattern to a set of typed callback functions that handle joins, messages, and cleanup.

## Topics and patterns

Topics are colon-delimited string identifiers. Patterns can be exact matches, legacy trailing prefix wildcards, or segment-aware wildcards:

```gleam
import beryl/topic

// Exact: only matches "room:lobby"
topic.parse_pattern("room:lobby")  // -> Exact("room:lobby")

// Wildcard: matches "room:lobby", "room:123", etc.
topic.parse_pattern("room:*")  // -> Wildcard("room:")

// Segment wildcard: matches one complete segment per "*"
topic.parse_pattern("document:*:ops")
// -> SegmentWildcard(["document", "*", "ops"])

// Multi-segment wildcard: extract tenant and document IDs
topic.parse_pattern("document:*:*")
// -> SegmentWildcard(["document", "*", "*"])

// Single trailing "*" keeps prefix wildcard behavior
topic.parse_pattern("document:tenant-a:*")
// -> Wildcard("document:tenant-a:")

// Extract the dynamic part
topic.extract_id(Wildcard("room:"), "room:lobby")  // -> Ok("lobby")

// Extract multiple dynamic segments
topic.extract_wildcards(
  topic.parse_pattern("document:*:*"),
  "document:tenant-a:doc-42",
)
// -> Ok(["tenant-a", "doc-42"])

// Parse topic segments
topic.segments("room:lobby")  // -> ["room", "lobby"]
topic.namespace("room:lobby")  // -> Ok("room")
```

Use `document:tenant-a:*` to route all documents for one tenant while keeping the existing trailing-wildcard prefix semantics. Use `document:*:*` when a handler needs to extract both tenant and document IDs from a topic with the exact shape `document:{tenant_id}:{document_id}`:

```gleam
let pattern = topic.parse_pattern("document:*:*")

case topic.extract_wildcards(pattern, "document:tenant-a:doc-42") {
  Ok([tenant_id, document_id]) -> {
    // tenant_id == "tenant-a"
    // document_id == "doc-42"
  }
  _ -> {
    // Topic did not match the expected document shape.
  }
}
```

## Defining a channel

Channels are built using a builder pattern starting with `channel.new()`:

```gleam
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

/// Typed assigns — compile-time checked socket state
pub type RoomAssigns {
  RoomAssigns(user_id: String, room_id: String)
}

pub fn new() -> Channel(RoomAssigns, info) {
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
  payload: Dynamic,
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

:::tip[Authenticate once at connect time]
If every topic needs the same per-socket auth (e.g. the same JWT), validate it
**once** with the transport-level `on_connect` hook instead of repeating the
check in every `join`. `on_connect` runs once per socket, can reject the whole
connection before any join, and can seed initial assigns that this `join`
callback reads via `socket.get_assigns`. See
[WebSocket Transport → Authentication](/guides/websocket#authentication).
:::

Called for each incoming text message. The `event` string identifies the message type:

```gleam
fn handle_in(
  event: String,
  payload: Dynamic,
  socket: Socket(RoomAssigns),
) -> HandleResult(RoomAssigns) {
  case event {
    "new_message" -> {
      let text_decoder = {
        use text <- decode.field("text", decode.string)
        decode.success(text)
      }
      let reply_payload = case channel.decode_payload(payload, text_decoder) {
        Ok(text) -> json.object([#("text", json.string(text))])
        Error(_) -> channel.error("invalid payload")
      }
      // Reply to the sender — event arg is ignored, phx_reply is always sent
      channel.Reply("ok", reply_payload, socket)
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
| `Reply(event, payload, socket)` | Send a `phx_reply` tied to the client message ref (only meaningful from `handle_in`; see note below) |
| `Push(event, payload, socket)` | Send a server-initiated message with no ref |
| `Stop(reason)` | Terminate the channel |

:::note[Reply vs Push from handle_info]
`Reply` is designed for `handle_in`, where the coordinator has a client message ref to reply to. When returned from `handle_info`, there is no client ref, so the coordinator sends it as a push instead. Prefer `Push` in `handle_info` to make this intent explicit.
:::

### Binary handler

Handle raw binary WebSocket frames when the configured codec does not decode binary frames:

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

### Server-originated message handler

Called when an OTP process sends a message directly to this channel context via `beryl.send_info`. Use this to push server-driven updates (e.g., database change notifications, timer ticks, background job results).

The handler receives the **typed** message you sent — there is no `Dynamic` and no unsafe cast. Channels are parameterized as `Channel(assigns, info)`, where `info` is your server-message type:

```gleam
type ServerMessage {
  Tick(at: Int)
  Notify(text: String)
}

fn handle_info(
  message: ServerMessage,
  socket: Socket(RoomAssigns),
) -> HandleResult(RoomAssigns) {
  case message {
    Tick(at) ->
      channel.Push(
        "tick",
        json.object([#("at", json.int(at))]),
        socket,
      )
    Notify(text) ->
      channel.Push(
        "notification",
        json.object([#("text", json.string(text))]),
        socket,
      )
  }
}

// Register the handler when building the channel
channel.new(join)
|> channel.with_handle_in(handle_in)
|> channel.with_handle_info(handle_info)
```

Because the `info` type is recovered by the channel, you match on `message` directly with exhaustive pattern matching — no `gleam/dynamic/decode` round-trip and no identity FFI cast in application code.

#### Sending messages with send_info

Use `beryl.send_info` from any process to deliver a message to a specific socket/topic pair:

```gleam
// In a background process or timer callback:
beryl.send_info(channels, socket_id, "room:lobby", Notify("hello!"))
```

If the socket is not connected, the topic is not joined, or no `handle_info` is registered, the message is silently ignored.

#### Timer and background job patterns

A common use case is scheduling periodic pushes to a specific client. Spawn a process when the client joins and cancel it in `terminate`:

```gleam
import gleam/erlang/process

fn join(topic, _payload, socket) -> JoinResult(RoomAssigns) {
  let socket_id = socket.id(socket)

  // Spawn a timer process that sends a tick every 5 seconds
  let _pid = process.spawn(fn() {
    let rec = process.new_subject()
    timer_loop(channels, socket_id, topic, rec)
  })

  channel.JoinOk(reply: None, socket: socket)
}

fn timer_loop(channels, socket_id, topic, _self) {
  process.sleep(5000)
  beryl.send_info(channels, socket_id, topic, Tick(erlang.system_time(erlang.Millisecond)))
  timer_loop(channels, socket_id, topic, _self)
}
```

For production use, prefer OTP-based timers (e.g., Erlang's `:timer.send_interval`) over bare recursion, and track the timer PID in assigns so you can cancel it in `terminate`.

## Registering channels

Register channels with the beryl system using topic patterns:

```gleam
import beryl
import beryl/wire

let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))

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

## Next steps

- [Reference](/reference/) — module map, wire protocol details, and the broadcast/push cheatsheet
- [Presence guide](/guides/presence/) — track who is online and broadcast presence diffs to clients
- [Groups guide](/guides/groups/) — broadcast a single event to multiple topics at once
- [PubSub guide](/guides/pubsub/) — distributed messaging for multi-node deployments
- [Error Handling guide](/guides/error-handling/) — rejected joins, rate limits, and client-visible error shapes
