---
title: beryl/transport
description: Transport SPI — the contract between beryl core and WebSocket transport
---

Transport SPI — the contract between beryl core and WebSocket transport
 implementations such as the `beryl_mist` package.

 A transport implementation:
 1. Admits a connection (origin/auth policy is the transport's concern),
    acquiring a slot with `acquire_connection_slot` and binding it with
    `bind_connection_slot`.
 2. Announces the socket with `socket_connected` then `register_closer`.
 3. Decodes inbound frames with the codec from `active_codec` (see
    `beryl/wire/codec`) and routes them with `route_decoded` /
    `route_binary`, shedding over-rate frames via `new_message_limiter` /
    `take_token` and oversized frames via `max_inbound_frame_bytes`.
 4. Announces disconnects with `socket_disconnected` and releases the
    slot with `release_connection_slot`.

## Types

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

## Type aliases

### `ConnectionPermit`

A held per-IP connection slot returned by `acquire_connection_slot`.

 Opaque so Beryl can restructure the connection limiter without breaking
 transport authors. Hold it for the lifetime of the connection and pass it
 to `release_connection_slot` when the connection closes. When no per-IP
 limit is configured the permit is an admit-everything placeholder and
 releasing it is a no-op.

```gleam
pub type ConnectionPermit = beryl.ConnectionPermit
```

## Functions

### `acquire_connection_slot`

Try to acquire a configured per-IP connection slot.

 Transports call this before admitting a connection, passing the **real
 socket peer IP**. Do not pass a client-supplied address (e.g. from
 `X-Forwarded-For`): a spoofed value would defeat the per-IP limit. Returns
 `Ok(permit)` when admitted (release the permit with
 `release_connection_slot` on close; when no limit is configured every
 connection is admitted), or `Error(Nil)` when the peer is already at its
 limit.

```gleam
pub fn acquire_connection_slot(
  sockets: beryl.Sockets,
  ip: String
) -> Result(beryl.ConnectionPermit, Nil)
```

### `active_codec`

The wire codec configured for these sockets. Transports decode inbound
 frames with it in the connection process.

```gleam
pub fn active_codec(beryl.Sockets) -> codec.Codec
```

### `bind_connection_slot`

Bind an acquired connection slot to the calling process.

 Call this from the long-lived connection process (e.g. the WebSocket
 handler's init) after `acquire_connection_slot`. The limiter monitors the
 caller so the slot is reclaimed even if the connection process dies
 without running its close path — otherwise crashed connections would
 permanently exhaust their IP's slots.

```gleam
pub fn bind_connection_slot(permit: beryl.ConnectionPermit) -> Nil
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

### `max_inbound_frame_bytes`

The configured inbound frame size cap. Transports close a connection
 whose assembled frame exceeds this many bytes, before wire decoding.

```gleam
pub fn max_inbound_frame_bytes(beryl.Sockets) -> Int
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

### `release_connection_slot`

Release a per-IP connection slot acquired with `acquire_connection_slot`.

 Call from the process the permit was bound to (or from an unbound
 process when releasing before the connection was established).

```gleam
pub fn release_connection_slot(permit: beryl.ConnectionPermit) -> Nil
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

### `runtime_pid`

The pid of the runtime that owns a transport's connections, or
 `Error(Nil)` when it is not currently running (pre-start or a restart
 window).

 Call this in the connection process right after upgrade. On `Ok(pid)`,
 monitor `pid` and close the connection on its `Down`, so a runtime crash
 or restart never leaves a zombie connection whose frames are silently
 dropped by a runtime that no longer knows the socket. On `Error(Nil)` the
 connection cannot be owned — refuse it rather than admit a dead socket.

```gleam
pub fn runtime_pid(beryl.Sockets) -> Result(process.Pid, Nil)
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
