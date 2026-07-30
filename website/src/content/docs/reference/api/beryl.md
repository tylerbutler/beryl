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

 beryl doesn't start an unmanaged process — `beryl/supervisor` builds a
 child specification for your application's own OTP supervisor.

 ```gleam
 import beryl
 import beryl/channel
 import beryl/group
 import beryl/presence
 import beryl/pubsub
 import beryl/supervisor
 import beryl/wire
 import gleam/option.{Some}
 import gleam/otp/static_supervisor

 pub fn main() {
   // Optional: start PubSub for distributed messaging
   let ps = pubsub.start(pubsub.default_config())

   // Configure channels (with presence and groups), then add beryl's
   // child specification to your application supervisor.
   let beryl_config =
     supervisor.config(beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps))
     |> supervisor.with_presence(presence.default_config("node1"))
     |> supervisor.with_groups()

   let assert Ok(_root) =
     static_supervisor.new(static_supervisor.OneForOne)
     |> static_supervisor.add(supervisor.start(beryl_config))
     |> static_supervisor.start()

   let channels = supervisor.channels(beryl_config)
   let assert Some(groups) = supervisor.groups(beryl_config)

   // Register a channel handler
   let _ = beryl.register(channels, "room:*", room_channel.new())

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

Configuration for the channels system.

 This type is opaque: construct it with `config` and adjust it with the
 `with_*` builder functions. Keeping it opaque lets Beryl add configuration
 options in the future without a breaking change.

```gleam
pub type Config
```

### `ConnectionPermit`

A held per-IP connection slot returned by `acquire_connection_slot`.

 Opaque so Beryl can restructure the connection limiter without breaking
 transport authors. Hold it for the lifetime of the connection and pass it
 to `release_connection_slot` when the connection closes. When no per-IP
 limit is configured the permit is an admit-everything placeholder and
 releasing it is a no-op.

```gleam
pub type ConnectionPermit
```

### `LoggingConfig`

Logging configuration for Beryl diagnostics.

 This type is opaque: construct it with `logging_config` and adjust it with
 the `with_*` builder functions so Beryl can add logging options without a
 breaking change.

```gleam
pub type LoggingConfig
```

### `LogLevel`

Logging verbosity for Beryl's internal loggers.

 The variants carry a `Level` suffix so `ErrorLevel` does not shadow the
 prelude's `Result` `Error` constructor when imported unqualified.

```gleam
pub type LogLevel {
  DebugLevel
  InfoLevel
  WarnLevel
  ErrorLevel
}
```

### `RegisteredChannel`

A typed handle returned when a channel is registered.

 Pass this handle to `send_info` so the compiler can prove that the message
 matches the receiving channel's `info` type. The handle also identifies the
 exact registered channel used for a joined socket/topic pair.

 The `assigns` and `info` parameters are phantom: they carry the registered
 channel's types so `send_info` is type-checked, while the handle itself
 stores only the coordinator subject and the registration id.

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

The topic pattern is invalid. Patterns must be non-empty and must not
 contain control characters (codepoints 0–31 or 127).

## Functions

### `acquire_connection_slot`

Try to acquire a configured per-IP connection slot for transports.

 Transports call this before admitting a connection, passing the **real
 socket peer IP**. Do not pass a client-supplied address (e.g. from
 `X-Forwarded-For`): a spoofed value would defeat the per-IP limit. Returns
 `Ok(permit)` when admitted (release the permit with
 `release_connection_slot` on close; when no limit is configured every
 connection is admitted), or `Error(Nil)` when the peer is already at its
 limit.

```gleam
pub fn acquire_connection_slot(
  Channels,
  String
) -> Result(ConnectionPermit, Nil)
```

### `bind_connection_slot`

Bind an acquired connection slot to the calling process.

 Call this from the long-lived connection process (e.g. the WebSocket
 handler's init) after `acquire_connection_slot`. The limiter monitors the
 caller so the slot is reclaimed even if the connection process dies
 without running its close path — otherwise crashed connections would
 permanently exhaust their IP's slots.

```gleam
pub fn bind_connection_slot(ConnectionPermit) -> Nil
```

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

### `max_inbound_frame_bytes`

Return the configured inbound frame size cap for transports.

```gleam
pub fn max_inbound_frame_bytes(Channels) -> Int
```

### `register`

Register a channel handler for a topic pattern

 Patterns can be exact matches like "room:lobby", legacy prefix wildcards
 like "room:*" which match any topic starting with "room:", or segment
 wildcards like "document:*:ops" where "*" matches one complete segment.
 The bare pattern "*" is a catch-all that matches every topic.

 Patterns are validated at registration: they must be non-empty and must
 not contain control characters (codepoints 0–31 or 127). Invalid patterns
 are rejected with `InvalidPattern`.

 Panics if the coordinator actor is unavailable or does not reply within
 5 seconds (e.g. during a supervisor restart window after a crash).

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

### `release_connection_slot`

Release a per-IP connection slot acquired by a transport.

 Call from the process the permit was bound to (or from an unbound
 process when releasing before the connection was established).

```gleam
pub fn release_connection_slot(ConnectionPermit) -> Nil
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

### `with_channel_rate`

Configure per-channel message rate limiting.

 The limiter applies only after a socket has joined a topic. Active
 per-socket channel buckets are capped by default; use
 `with_channel_rate_max_keys_per_socket` to adjust the cap.

```gleam
pub fn with_channel_rate(
  Config,
  per_second: Int,
  burst: Int
) -> Config
```

### `with_channel_rate_max_keys_per_socket`

Configure the maximum active per-channel rate-limit buckets per socket.

 Values <= 0 disable the cap. The default is 1000.

```gleam
pub fn with_channel_rate_max_keys_per_socket(
  Config,
  max_keys: Int
) -> Config
```

### `with_heartbeat`

Configure heartbeat timing.

 `interval_ms` is **client-advisory only**: it is the interval clients should
 use for their own outbound pings. The server never reads it and does not use
 it to schedule anything — it exists purely to communicate a suggested ping
 cadence to clients.

 `timeout_ms` is the server-side staleness window — a socket that sends no
 heartbeat within this window is evicted. The server derives its internal
 check interval as `timeout_ms / 2` (integer division), so `timeout_ms` must
 be at least 2; smaller values are rejected by `start` with
 `InvalidHeartbeatTimeout` because a check interval of 0 would disable
 eviction. The defaults are 30000 ms and 60000 ms respectively.

```gleam
pub fn with_heartbeat(
  Config,
  interval_ms: Int,
  timeout_ms: Int
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

### `with_logging`

Configure Beryl's internal logging.

```gleam
pub fn with_logging(
  Config,
  LoggingConfig
) -> Config
```

### `with_max_connections`

Configure the maximum number of concurrent connections allowed across the
 whole node, regardless of source IP.

 A value of 0 (the default) means unlimited. When a limit is set, a transport
 admits a new connection only while the node is below the limit and rejects
 it (before allocating any long-lived channel/coordinator state) otherwise;
 the slot is freed when the connection closes, its process dies, or its
 handshake/setup fails. The check-and-increment is atomic inside the limiter
 actor, so a burst of concurrent opens cannot materially exceed the ceiling.

 ## Composition with per-IP limits

 This node-wide ceiling composes with `with_max_connections_per_ip`: when
 both are set a connection must be under *both* limits to be admitted. The
 per-IP limit throttles any single abusive peer, while this global ceiling
 bounds the node's total resource use so that many distinct source addresses
 (for example a botnet or IPv6 address rotation) still cannot exhaust the
 node's process, socket, and coordinator budget — a case a per-IP limit alone
 cannot stop.

 ## Composition with external load balancers

 This ceiling is enforced per BEAM node. If you run several nodes behind a
 load balancer, each node enforces its own limit independently, so the
 cluster's effective ceiling is roughly `max_connections × node_count`
 (subject to how the balancer distributes connections). Size the per-node
 value against a single node's capacity, and use the load balancer's own
 global connection/rate controls when you need a cluster-wide cap.

```gleam
pub fn with_max_connections(
  Config,
  max_connections: Int
) -> Config
```

### `with_max_connections_per_ip`

Configure the maximum number of concurrent connections allowed per client
 IP address.

 A value of 0 (the default) means unlimited. When a limit is set, a transport
 admits a new connection only while the peer is below the limit and rejects
 it otherwise; the slot is freed when the connection closes.

 ## Which IP is used

 The limit is enforced on the **real socket peer IP** as reported by the
 transport (for the Mist transport, the address of the TCP connection).
 Beryl deliberately does **not** trust or parse forwarded headers such as
 `X-Forwarded-For`, because a client can set them freely and would otherwise
 be able to spoof its address and bypass this limit.

 If Beryl runs behind a trusted reverse proxy or load balancer, every
 connection shares the proxy's address, so a per-IP limit throttles all
 clients as a single IP. In that topology you must resolve the real client
 IP yourself at the proxy layer (for example, by enforcing limits there). A
 built-in trusted-proxy opt-in may be added in a future release. See the
 WebSocket transport guide for deployment guidance.

```gleam
pub fn with_max_connections_per_ip(
  Config,
  max_connections: Int
) -> Config
```

### `with_max_event_length`

Configure the maximum allowed byte length for client-supplied event name
 strings.

 Event names longer than `max_length` bytes are dropped before reaching a
 channel handler. The default is 64.

```gleam
pub fn with_max_event_length(
  Config,
  max_length: Int
) -> Config
```

### `with_max_inbound_frame_bytes`

Configure the maximum allowed inbound WebSocket frame size in bytes.

 The limit is enforced **post-assembly**: the transport (Mist/gramps)
 buffers and assembles a complete frame first, and only then does Beryl
 measure it and close the connection if it exceeds `max_bytes`. This bounds
 per-message processing cost (decode, routing, rate-limit accounting), but
 it does **not** by itself bound transport memory. A hostile client can
 declare a huge payload and stream it slowly, or send many fragmented
 continuation frames, and the transport's receive buffer grows before this
 check ever runs — so this setting alone does not stop a single connection
 from exhausting node memory.

 For a true transport memory bound you **must** place an edge proxy or load
 balancer in front of Beryl and configure a WebSocket frame-size limit
 there (and a matching request/body size limit). Beryl's per-IP connection
 limit and per-socket message-rate limit do not mitigate this vector. See
 the "Security & deployment" section of the README and
 `docs/security/frame-buffering-followup.md` for details.

 Values <= 0 disable the cap. The default is 1 MiB.

```gleam
pub fn with_max_inbound_frame_bytes(
  Config,
  max_bytes: Int
) -> Config
```

### `with_max_joined_topics_per_socket`

Configure the maximum number of topics a socket may join at once.

 Values <= 0 disable the cap. The default is 1000.

```gleam
pub fn with_max_joined_topics_per_socket(
  Config,
  max_topics: Int
) -> Config
```

### `with_max_topic_length`

Configure the maximum allowed byte length for client-supplied topic
 strings.

 Topics longer than `max_length` bytes are rejected with a `phx_reply`
 error before reaching a channel handler, bounding the size of keys stored
 in the coordinator's topic registry. The default is 256.

```gleam
pub fn with_max_topic_length(
  Config,
  max_length: Int
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
  pubsub.PubSub(json.Json)
) -> Config
```
