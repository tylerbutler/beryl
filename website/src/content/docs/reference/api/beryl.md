---
title: beryl
description: Beryl - Type-safe real-time communication
---

Beryl - Type-safe real-time communication

 A standalone Gleam library for building real-time applications on the BEAM.
 Provides WebSocket channels, distributed presence tracking, pub/sub
 messaging, and channel groups.

 ## Features

 - **Channels** — Topic-based WebSocket messaging with pattern matching
   (`beryl`, `beryl/channel`)
 - **PubSub** — Distributed publish/subscribe via Erlang `pg`
   (`beryl/pubsub`)
 - **Presence** — Distributed presence tracking backed by a causal-context
   CRDT (add-wins observed-remove set) (`beryl/presence`)
 - **Groups** — Named collections of topics for multi-topic broadcasting
   (`beryl/group`)

 ## Quick Start

 ```gleam
 import beryl
 import beryl/channel
 import beryl/pubsub
 import beryl/presence
 import beryl/group
 import beryl/wire

 pub fn main() {
   // Optional: start PubSub for distributed messaging
   let ps = pubsub.start(pubsub.default_config())

   // Start channels system (with or without PubSub)
   let config = beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps)
   let assert Ok(channels) = beryl.start(config)

   // Register a channel handler
   let _ = beryl.register(channels, "room:*", room_channel.new())

   // Start presence tracking
   let assert Ok(p) = presence.start(presence.default_config("node1"))

   // Start channel groups
   let assert Ok(groups) = group.start()
   let assert Ok(Nil) = group.create(groups, "team:eng")
   let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")

   // Broadcast to all topics in a group
   group.broadcast(groups, channels, "team:eng", "announce", payload)
 }
 ```

## Types

### `Channels`

Channels system handle.

 This opaque handle is returned by `start` and passed to registration,
 broadcast, bridge, group, supervisor, and transport functions. Its internal
 actor protocol is intentionally hidden so Beryl can evolve coordinator
 internals without breaking application code.

```gleam
pub type Channels
```

### `Config`

Configuration for the channels system

```gleam
pub type Config {
  Config(
    codec: codec.Codec,
    heartbeat_interval_ms: Int,
    heartbeat_timeout_ms: Int,
    max_connections_per_ip: Int,
    pubsub: option.Option(pubsub.PubSub),
    message_rate: Int,
    message_burst: Int,
    join_rate: Int,
    join_burst: Int,
    channel_rate: Int,
    channel_burst: Int,
    channel_rate_max_keys_per_socket: Int,
    max_topic_length: Int,
    max_event_length: Int,
    max_inbound_frame_bytes: Int,
    max_joined_topics_per_socket: Int,
    logging: LoggingConfig
  )
}
```

### `LoggingConfig`

Logging configuration for Beryl diagnostics.

```gleam
pub type LoggingConfig {
  LoggingConfig(
    level: LogLevel,
    include_payloads: Bool,
    payload_preview_bytes: Int
  )
}
```

### `LogLevel`

Logging verbosity for Beryl's internal loggers.

```gleam
pub type LogLevel {
  Debug
  Info
  Warn
  Error
}
```

### `RegisteredChannel`

A typed handle returned when a channel is registered.

 Pass this handle to `send_info` so the compiler can prove that the message
 matches the receiving channel's `info` type. The handle also identifies the
 exact registered channel used for a joined socket/topic pair.

```gleam
pub type RegisteredChannel(a, b)
```

### `RegisterError`

Errors when registering a channel handler.

```gleam
pub type RegisterError {
  PatternAlreadyRegistered(String)
  InvalidPattern(String)
}
```

#### Constructors

##### `PatternAlreadyRegistered(String)`

A handler is already registered for this exact topic pattern.

##### `InvalidPattern(String)`

The topic pattern is invalid.

### `StartError`

Errors when starting channels

```gleam
pub type StartError {
  CoordinatorStartFailed(error.StartFailure)
  InvalidHeartbeatTimeout
}
```

#### Constructors

##### `CoordinatorStartFailed(error.StartFailure)`

The coordinator actor failed to start.

##### `InvalidHeartbeatTimeout`

heartbeat_timeout_ms must be > 0 (it is used to derive the check interval)

## Functions

### `broadcast`

Broadcast a message to all subscribers of a topic

 This sends the message to all sockets subscribed to the topic.

 ## Example

 ```gleam
 beryl.broadcast(
   channels,
   "room:lobby",
   "new_message",
   json.object([#("text", json.string("Hello!"))]),
 )
 ```

```gleam
pub fn broadcast(
  Channels,
  String,
  String,
  json.Json
) -> Nil
```

### `broadcast_from`

Broadcast a message to all subscribers except one socket

 Useful for broadcasting a message to everyone except the sender.
 When PubSub is configured, the excluded socket ID is preserved across
 coordinators so clustered deployments do not echo the event back to that
 socket on another node.

 ## Example

 ```gleam
 // In a channel handler, broadcast to others
 beryl.broadcast_from(
   channels,
   socket_id,
   "room:lobby",
   "user_typing",
   json.object([#("user", json.string("alice"))]),
 )
 ```

```gleam
pub fn broadcast_from(
  Channels,
  String,
  String,
  String,
  json.Json
) -> Nil
```

### `broadcast_presence_diff`

Broadcast a Phoenix-compatible `presence_diff` event for a topic.

 This encodes the topic's joins and leaves as:

 ```json
 {
   "joins": { "user:1": { "metas": [{ "status": "online" }] } },
   "leaves": { "user:2": { "metas": [{ "status": "offline" }] } }
 }
 ```

 When the channels system was started with PubSub, the broadcast is
 distributed using the same semantics as `broadcast`.

```gleam
pub fn broadcast_presence_diff(
  Channels,
  String,
  presence.Diff
) -> Nil
```

### `config`

Build a configuration with sensible defaults.

 A `codec` is required — beryl no longer ships an implicit Phoenix
 default. Pass `wire.phoenix_codec()` to keep Phoenix wire compatibility,
 or your own `Codec` for a custom framing.

```gleam
pub fn config(codec.Codec) -> Config
```

### `extract_topic_id`

Get the topic ID from a topic using wildcard extraction

 For pattern "room:*" and topic "room:lobby", returns Ok("lobby").
 For segment wildcard patterns with one wildcard segment, returns that
 segment. Use `topic.extract_wildcards` when extracting multiple segments.

 ## Example

 ```gleam
 let assert Ok("lobby") = topic.extract_id(topic.Wildcard("room:"), "room:lobby")
 ```

```gleam
pub fn extract_topic_id(
  topic.TopicPattern,
  String
) -> Result(String, topic.ExtractError)
```

### `logging_config`

Build a logging configuration.

 Payloads are excluded by default to avoid accidental sensitive-data
 exposure. Use `with_payload_preview_bytes` to adjust the bounded preview
 size when payload previews are enabled.

```gleam
pub fn logging_config(
  level: LogLevel,
  include_payloads: Bool
) -> LoggingConfig
```

### `register`

Register a channel handler for a topic pattern

 Patterns can be exact matches like "room:lobby", legacy prefix wildcards
 like "room:*" which match any topic starting with "room:", or segment
 wildcards like "document:*:ops" where "*" matches one complete segment.

 ## Example

 ```gleam
 // Create a typed channel
 let chat_channel = channel.new(fn(topic, payload, socket) {
   // Handle join
   channel.JoinOk(reply: None, socket: socket)
 })
 |> channel.with_handle_in(fn(event, payload, socket) {
   // Handle incoming messages
   channel.NoReply(socket)
 })

 // Register it with a legacy prefix wildcard
 let assert Ok(chat) = beryl.register(channels, "chat:*", chat_channel)

 // Exact topic
 let assert Ok(lobby) = beryl.register(channels, "room:lobby", lobby_channel)

 // Segment-aware wildcard
 let assert Ok(ops) = beryl.register(channels, "document:*:ops", ops_channel)
 ```

```gleam
pub fn register(
  Channels,
  String,
  channel.Channel(a, b)
) -> Result(RegisteredChannel(a, b), RegisterError)
```

### `send_info`

Send a typed server-originated OTP message to a joined channel context.

 The `registered` handle carries the receiving channel's `info` type, so the
 compiler rejects messages for incompatible channels. The coordinator also
 verifies that the socket/topic pair was joined through that same registered
 channel before dispatching the callback. If the socket is not connected, the
 topic is not joined, or the registered channel does not match the joined
 channel, the message is ignored.

```gleam
pub fn send_info(
  RegisteredChannel(a, b),
  String,
  String,
  b
) -> Nil
```

### `start`

Start the channels system

 Call once at application startup. Returns a handle that can be passed
 to the WebSocket transport and used for broadcasting.

 Heartbeat timeout enforcement is configured via `heartbeat_interval_ms`
 and `heartbeat_timeout_ms` in the Config. The coordinator checks for
 stale sockets at `heartbeat_interval_ms` and evicts any socket that
 hasn't sent a heartbeat within `heartbeat_timeout_ms`.

 ## Example

 ```gleam
 pub fn main() {
   let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
   // Use channels...
 }
 ```

```gleam
pub fn start(Config) -> Result(Channels, StartError)
```

### `with_channel_rate`

Configure per-channel message rate limiting

```gleam
pub fn with_channel_rate(
  Config,
  per_second: Int,
  burst: Int
) -> Config
```

### `with_join_rate`

Configure per-socket join rate limiting

```gleam
pub fn with_join_rate(
  Config,
  per_second: Int,
  burst: Int
) -> Config
```

### `with_max_inbound_frame_bytes`

Configure the maximum allowed inbound WebSocket frame size in bytes.

```gleam
pub fn with_max_inbound_frame_bytes(
  Config,
  max_bytes: Int
) -> Config
```

### `with_max_joined_topics_per_socket`

Configure the maximum number of topics a socket may join at once.

```gleam
pub fn with_max_joined_topics_per_socket(
  Config,
  max_topics: Int
) -> Config
```

### `with_logging`

Configure Beryl's internal logging.

```gleam
pub fn with_logging(
  Config,
  LoggingConfig
) -> Config
```

### `with_message_rate`

Configure per-socket message rate limiting

```gleam
pub fn with_message_rate(
  Config,
  per_second: Int,
  burst: Int
) -> Config
```

### `with_payload_preview_bytes`

Configure the maximum payload/frame preview length for logs.

```gleam
pub fn with_payload_preview_bytes(
  LoggingConfig,
  bytes: Int
) -> LoggingConfig
```

### `with_pubsub`

Add PubSub to a configuration for distributed broadcasts

```gleam
pub fn with_pubsub(
  Config,
  pubsub.PubSub
) -> Config
```
