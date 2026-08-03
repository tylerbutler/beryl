---
title: beryl/transport
description: Transport SPI — the contract between beryl core and WebSocket transport
---

Transport SPI — the contract between beryl core and WebSocket transport
 implementations such as the `beryl_mist` package.

 Transports built on `gleam/http` requests use `beryl/transport/server`,
 which layers the upgrade admission pipeline, connection lifecycle, and
 inbound frame pipeline on top of this module. The functions here are the
 low-level contract that pipeline is built on: announce sockets
 (`socket_connected`, `register_closer`, `socket_disconnected`), route
 inbound frames (`route_decoded`, `route_binary`) decoded with the codec
 from `active_codec` (see `beryl/wire/codec`), and tie connection
 lifetimes to the owning runtime (`runtime_pid`).

## Type aliases

### `ConnectionPermit`

A held per-IP connection slot, acquired by the admission pipeline in
 `beryl/transport/server` (`server.upgrade`) and released by
 `server.close_connection` / `server.release_slot_on_failed_handshake`.

 Opaque so Beryl can restructure the connection limiter without breaking
 transport authors. When no per-IP limit is configured the permit is an
 admit-everything placeholder and releasing it is a no-op.

```gleam
pub type ConnectionPermit = beryl.ConnectionPermit
```

## Functions

### `active_codec`

The wire codec configured for these sockets. Transports decode inbound
 frames with it in the connection process.

```gleam
pub fn active_codec(beryl.Sockets) -> codec.Codec
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

Route a raw binary frame. When the codec has a binary decoder the frame
 is decoded in the runtime and dispatched like any inbound message;
 otherwise it fans out to the socket's joined topics as `Binary` events
 delivered to `update`.

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
