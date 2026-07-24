---
title: beryl/transport
description: Transport SPI — the contract between beryl core and WebSocket transport
---

Transport SPI — the contract between beryl core and WebSocket transport
 implementations such as the `beryl_mist` package.

 A transport implementation:
 1. Admits a connection (origin/auth policy is the transport's concern),
    acquiring a slot with `beryl.acquire_connection_slot` and binding it
    with `beryl.bind_connection_slot`.
 2. Announces the socket with `socket_connected` then `register_closer`.
 3. Decodes inbound frames with the codec from `active_codec` (see
    `beryl/wire/codec`) and routes them with `route_decoded` /
    `route_binary`, shedding over-rate frames via `new_message_limiter` /
    `take_token` and oversized frames via `beryl.max_inbound_frame_bytes`.
 4. Announces disconnects with `socket_disconnected` and releases the
    slot with `beryl.release_connection_slot`.

## Types

### `ConnectionOwner`

The lifecycle relationship between a transport connection and the runtime
 that owns it.

 App-side dispatch systems own their connections through a supervised
 runtime. A transport should monitor the owning runtime and close the
 connection when it dies, so a runtime crash or restart never leaves a
 zombie connection whose frames are silently dropped by a runtime that no
 longer knows the socket.

```gleam
pub type ConnectionOwner {
  OwnerAlive(pid: process.Pid)
  OwnerUnavailable
}
```

#### Constructors

##### `OwnerAlive(pid: process.Pid)`

The owning runtime is alive at this pid. Monitor it and close the
 connection when it goes down.

##### `OwnerUnavailable`

The runtime is not currently running (pre-start or a restart window). A
 new connection cannot be owned, so the transport must refuse it rather
 than admit a dead socket.

### `Logger`

A named logger for transport diagnostics, routed through beryl's
 configured logging backend.

```gleam
pub type Logger
```

### `RateLimiter`

A per-connection token bucket enforcing the configured message rate at
 the transport edge, so a flooding socket is shed before frames are
 decoded or enqueued on the runtime.

```gleam
pub type RateLimiter
```

## Functions

### `active_codec`

The wire codec configured for these sockets. Transports decode inbound
 frames with it in the connection process.

```gleam
pub fn active_codec(beryl.Sockets) -> codec.Codec
```

### `connection_owner`

Determine how a newly accepted connection is owned. Call this in the
 connection process right after upgrade; on `OwnerAlive(pid)` monitor `pid`
 and close on its `Down`, and on `OwnerUnavailable` close the connection
 immediately.

```gleam
pub fn connection_owner(beryl.Sockets) -> ConnectionOwner
```

### `log_warning`

Log a warning with structured metadata.

```gleam
pub fn log_warning(
  logger: Logger,
  message: String,
  metadata: List(#(String, String))
) -> Nil
```

### `logger`

Create a named transport logger (e.g. `"beryl.transport.mist"`).

```gleam
pub fn logger(String) -> Logger
```

### `new_message_limiter`

Create a fresh per-connection message limiter, `None` when no message
 rate is configured.

```gleam
pub fn new_message_limiter(beryl.Sockets) -> option.Option(RateLimiter)
```

### `register_closer`

Register a function that force-closes the socket's underlying connection
 so the runtime can actively evict it (e.g. heartbeat timeout) instead
 of leaving a zombie socket whose frames are silently dropped.

```gleam
pub fn register_closer(
  sockets: beryl.Sockets,
  socket_id: String,
  close: fn() -> Nil
) -> Nil
```

### `route_binary`

Route a raw binary frame, for codecs without a binary decoder (fans out
 to the socket's joined topics as `Binary` events delivered to `update`).

```gleam
pub fn route_binary(
  sockets: beryl.Sockets,
  socket_id: String,
  data: BitArray
) -> Nil
```

### `route_decoded`

Route a transport-decoded inbound message to the runtime. Decode in
 the connection process (see `active_codec`) so parse cost and malformed
 input never reach the shared runtime.

```gleam
pub fn route_decoded(
  sockets: beryl.Sockets,
  socket_id: String,
  message: codec.Inbound
) -> Nil
```

### `socket_connected`

Announce a newly connected socket. `send`/`send_binary` deliver outbound
 frames on this connection. `seed` carries the upgrade request's
 connection data (path, query, headers, and any `with_on_connect`
 metadata), delivered to the app's `init` as `ConnectInfo.seed`. Call
 `register_closer` immediately after this.

```gleam
pub fn socket_connected(
  sockets: beryl.Sockets,
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  seed: socket.ConnectSeed
) -> Nil
```

### `socket_disconnected`

Announce that a socket's connection has closed.

```gleam
pub fn socket_disconnected(
  sockets: beryl.Sockets,
  socket_id: String
) -> Nil
```

### `take_token`

Take one token; returns the updated limiter and whether the frame is
 admitted. Transports drop the frame when `False`.

```gleam
pub fn take_token(RateLimiter) -> #(RateLimiter, Bool)
```
