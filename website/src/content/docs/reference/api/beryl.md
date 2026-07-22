---
title: beryl
description: Beryl - Type-safe real-time communication
---

Beryl - Type-safe real-time communication

 A standalone Gleam library for building real-time applications on the BEAM.
 Provides WebSocket channels, distributed presence tracking, pub/sub
 messaging, and channel groups.

 ## Features

 - **App-side dispatch** — One `start_app` entry point: the app supplies
   `init`/`update` per socket and routes topics itself (`beryl`,
   `beryl/event`)
 - **PubSub** — Distributed publish/subscribe via Erlang `pg`
   (`beryl/pubsub`)
 - **Presence** — Distributed presence tracking backed by a causal-context
   CRDT (add-wins observed-remove set) (`beryl/presence`)
 - **Groups** — Named collections of topics for multi-topic broadcasting
   (`beryl/group`)

 ## Quick Start

 ```gleam
 import beryl
 import beryl/event
 import beryl/wire

 pub fn main() {
   let assert Ok(channels) =
     beryl.start_app(
       beryl.config(wire.phoenix_codec()),
       init: fn(_info) { #(initial_model(), []) },
       update: update,
     )

   // Broadcast from anywhere holding the handle
   beryl.broadcast(channels, "room:lobby", "announce", payload)
 }
 ```

## Types

### `Channels`

Channels system handle.

 This opaque handle is returned by `start_app` and passed to broadcast,
 group, and transport functions. The runtime actor is generic over the
 app's `model`/`msg`; the handle reaches it through monomorphic closures
 captured at start. Its internals are intentionally hidden so Beryl can
 evolve them without breaking application code.

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

### `StartError`

Errors when starting channels

```gleam
pub type StartError {
  RuntimeStartFailed(error.StartFailure)
  InvalidHeartbeatTimeout
}
```

#### Constructors

##### `RuntimeStartFailed(error.StartFailure)`

The supervised runtime failed to start.

##### `InvalidHeartbeatTimeout`

`heartbeat_timeout_ms` must be at least 2. The server derives its staleness
 check interval as `heartbeat_timeout_ms / 2` (integer division), so a
 timeout of 1 would round down to a check interval of 0 — which disables
 heartbeat eviction entirely. `start` rejects such a config loudly rather
 than silently turning eviction off.

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

### `release_connection_slot`

Release a per-IP connection slot acquired by a transport.

 Call from the process the permit was bound to (or from an unbound
 process when releasing before the connection was established).

```gleam
pub fn release_connection_slot(ConnectionPermit) -> Nil
```

### `start_app`

Start an app-side dispatch system.

 One entry point replaces channel modules and registration: the app
 supplies `init`, producing the per-socket model when a socket connects,
 and `update`, receiving every event for the socket and returning the
 next model plus a list of effects. The app routes topics itself by
 matching on the event's topic — see `beryl/event` for the event and
 effect types.

 The returned `Channels` handle works with the same transports and
 broadcast/group helpers as `start`, but `register`/`send_info` do not
 apply: server-side messages are sent through the socket's typed
 `Sender` (`event.notify`) instead.

 ## Example

 ```gleam
 import beryl
 import beryl/event.{AcceptJoin, Broadcast, Join, Message, Next}

 pub fn main() {
   let assert Ok(channels) =
     beryl.start_app(
       beryl.config(wire.phoenix_codec()),
       init: fn(_info) { #(MyModel(joined: False), []) },
       update: fn(model, ev) {
         case ev {
           Join("room:" <> _, _payload, ref) ->
             Next(MyModel(joined: True), [AcceptJoin(ref, option.None)])
           Message(topic, "new_msg", payload, _ref) ->
             Next(model, [Broadcast(topic, "new_msg", relay(payload))])
           _ -> Next(model, [])
         }
       },
     )
 }
 ```

```gleam
pub fn start_app(
  Config,
  init: fn(event.ConnectInfo(a)) -> #(b, List(event.Effect)),
  update: fn(b, event.Event(a)) -> event.Next(b, a)
) -> Result(Channels, StartError)
```

### `stop`

Stop a channels system started by `start_app`.

 Drains sockets gracefully and shuts down the supervised runtime plus any
 auxiliary limiter actors owned by the `Channels` handle. Joined topics
 receive a `Closed` event before the runtime exits. After this call the
 `Channels` handle should no longer be used.

```gleam
pub fn stop(Channels) -> Nil
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
 the README's "Security" section for deployment guidance.

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

### `with_presence_handle`

Attach a presence handle for app-dispatch systems (`start_app`), used
 by the `PresenceTrack`/`PresenceUntrack` effects. Without a handle
 those effects are dropped with a warning.

```gleam
pub fn with_presence_handle(
  Config,
  presence: presence.Presence
) -> Config
```

### `with_pubsub`

Add PubSub to a configuration for distributed broadcasts

```gleam
pub fn with_pubsub(
  Config,
  pubsub.PubSub(json.Json)
) -> Config
```

### `with_topic_rate`

Configure a per-topic-pattern message rate limit for app-dispatch
 systems (`start_app`).

 Patterns use the same syntax as topic routing (`"room:*"`,
 `"document:*:ops"`, `"*"`). Limits are consulted in the order they were
 added and the first matching pattern wins; topics matching no pattern
 fall back to the global `with_channel_rate` limit. The limiter applies
 only after a socket has joined the topic.

```gleam
pub fn with_topic_rate(
  Config,
  pattern: String,
  per_second: Int,
  burst: Int
) -> Config
```
