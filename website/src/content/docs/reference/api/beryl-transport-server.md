---
title: beryl/transport/server
description: Server-agnostic WebSocket transport infrastructure.
---

Server-agnostic WebSocket transport infrastructure.

 This module carries everything a WebSocket transport package needs that
 does not depend on a particular web server: transport configuration and
 its builders, the upgrade admission pipeline (path matching, origin
 policy, `?vsn` negotiation, connection limits, `on_connect`
 authentication), per-connection lifecycle choreography, and the inbound
 frame pipeline (size caps, rate limiting, decoding, routing).

 Transport packages such as `beryl_mist` and `beryl_ewe` supply only the
 server-specific glue: the WebSocket upgrade call, frame sending, and peer
 IP extraction. All functions here are generic over the `gleam/http`
 request body type, so one config value works with any transport whose
 server exposes `gleam/http` requests.

## Types

### `ConnectError`

Errors returned from a transport `on_connect` callback.

```gleam
pub type ConnectError {
  ConnectRejected
}
```

#### Constructors

##### `ConnectRejected`

Reject the WebSocket upgrade with `403 Forbidden`.

### `ConnectionState`

State maintained per WebSocket connection.

```gleam
pub type ConnectionState
```

### `FrameOutcome`

What a transport should do with its connection after handling an inbound
 frame.

```gleam
pub type FrameOutcome {
  Continue(ConnectionState)
  Stop
}
```

#### Constructors

##### `Continue(ConnectionState)`

Keep the connection open with the updated state.

##### `Stop`

Close the connection (the frame exceeded the configured size cap).

### `SendRequest`

Outbound requests the runtime sends to a connection process. Transports
 receive these as their custom/user WebSocket message and act on them:
 send the frame, or close the connection.

```gleam
pub type SendRequest {
  SendText(String)
  SendBinary(BitArray)
  Close
}
```

#### Constructors

##### `Close`

Runtime-initiated close (e.g. heartbeat eviction).

### `TransportConfig`

Configuration for a WebSocket transport.

 Generic over the server's request body type (`body`), so the same config
 value works with any transport built on `gleam/http` requests.

```gleam
pub type TransportConfig(a)
```

## Functions

### `close_connection`

Clean up when a connection closes: release the held connection slot and
 announce the disconnect to the runtime.

```gleam
pub fn close_connection(ConnectionState) -> Nil
```

### `connect_seed`

Assemble the connection seed delivered to an app-dispatch system's
 `init` (`ConnectInfo.seed`). Systems that don't use connect metadata simply
 ignore it.

 `metadata` is the ordered list of string pairs returned by the
 configured `on_connect` callback (empty when none is configured or it
 returns no metadata); order and duplicate keys are preserved verbatim.

```gleam
pub fn connect_seed(
  request.Request(a),
  List(#(String, String))
) -> socket.ConnectSeed
```

### `default_config`

Create a default transport config with no connect hook.

 The resulting config seeds empty (`[]`) `ConnectSeed.metadata` and applies
 the `origin.SameOrigin` origin policy, which rejects cross-site WebSocket
 upgrades before the handshake (CSWSH protection). Same-origin upgrades and
 non-browser clients (no `Origin` header) are admitted without
 configuration.

 Add `with_on_connect` to authenticate connections and/or seed connect
 metadata. Use `with_allowed_origins` to pin an explicit allow-list, or
 `with_allow_all_origins` to opt out of origin checking entirely.

```gleam
pub fn default_config(String) -> TransportConfig(a)
```

### `handle_binary_frame`

Size-check, rate-check, and decode an inbound binary frame in the
 connection process. Codecs without a binary decoder keep the raw
 `transport.route_binary` fan-out, routed through the runtime.

 Oversized frames return `Stop` (close the connection); over-rate frames
 are shed silently; undecodable frames are logged and dropped.

```gleam
pub fn handle_binary_frame(
  ConnectionState,
  BitArray
) -> FrameOutcome
```

### `handle_text_frame`

Size-check, rate-check, and decode an inbound text frame in the
 connection process, so parse cost stays there and only valid,
 rate-admitted messages reach the shared runtime.

 Oversized frames return `Stop` (close the connection); over-rate frames
 are shed silently; undecodable frames are logged and dropped.

```gleam
pub fn handle_text_frame(
  ConnectionState,
  String
) -> FrameOutcome
```

### `handler`

Build a combined request handler that routes WebSocket upgrade requests
 to `upgrade` and everything else to `http_fallback`.

 `upgrade` receives the request and a fall-through thunk for upgrade
 requests on a non-matching path. Transport packages wrap this with their
 server-specific `upgrade` to expose a one-call combined handler.

```gleam
pub fn handler(
  upgrade: fn(request.Request(a), fn() -> response.Response(b)) -> response.Response(b),
  http_fallback: fn(request.Request(a)) -> response.Response(b)
) -> fn(request.Request(a)) -> response.Response(b)
```

### `init_connection`

Initialize a newly upgraded WebSocket connection in its connection
 process.

 Binds the held connection slot to the calling process (so the slot is
 reclaimed even if the process dies without a clean close), registers the
 socket and a runtime-triggered closer with the runtime, and monitors the
 owning runtime so a runtime crash or restart closes the connection rather
 than leaving a zombie socket whose frames a restarted runtime would
 silently drop. When the runtime is momentarily unavailable (a restart
 window) the connection is closed immediately so no orphaned socket is
 admitted.

 Returns the connection state and a selector (extending `base_selector`)
 that delivers `SendRequest` values from the runtime; the transport must
 select on it and act on each request. Call `close_connection` when the
 connection closes, and `logger_name` names the transport in decode
 warnings (e.g. `"beryl_mist"`).

```gleam
pub fn init_connection(
  sockets: beryl.Sockets,
  seed: socket.ConnectSeed,
  connection_permit: beryl.ConnectionPermit,
  base_selector: process.Selector(SendRequest),
  logger_name: String
) -> #(ConnectionState, process.Selector(SendRequest))
```

### `is_websocket_request`

Determine whether a request is a WebSocket upgrade request.

 Checks for the standard `Upgrade: websocket` header (case-insensitive).
 Use this to distinguish WebSocket handshakes from regular HTTP traffic on
 the same listener.

```gleam
pub fn is_websocket_request(request.Request(a)) -> Bool
```

### `release_slot_on_failed_handshake`

Release a held connection slot when a WebSocket handshake fails.

 A failed handshake (e.g. missing `Sec-WebSocket-Key`, reported as a
 status of 400 or above) never runs the connection's init/close callbacks,
 so the acquired slot must be released here or repeated bad handshakes
 would permanently exhaust the IP's slots. Pipe the server's upgrade
 response through this before returning it.

```gleam
pub fn release_slot_on_failed_handshake(
  response.Response(a),
  beryl.ConnectionPermit
) -> response.Response(a)
```

### `upgrade`

Run the shared upgrade admission pipeline for a request.

 When the request path matches `config.path`, the pipeline:
 1. Applies the configured origin policy and the `?vsn` version check,
    rejecting failures with `reject(403)`.
 2. Acquires a connection slot for `request_ip(request)` (per-IP and
    node-wide ceilings), rejecting with `reject(429)` when at a limit.
 3. Runs any `on_connect` callback; on `Error(ConnectRejected)` the slot is
    released and the request is rejected with `reject(403)`.
 4. Hands admitted requests to `accept` with the callback's connect
    metadata (empty when no callback is configured) and the held permit.

 Non-matching paths fall through to `next`.

 ## Path matching

 Both the request path and the configured path are normalised to
 `"/" <> string.join(segments, "/")` (no trailing or doubled slashes)
 before an exact-equality comparison, so `default_config("/socket/")`
 and a request for `/socket` match.

 ## Connection limits

 When `beryl.with_max_connections_per_ip` is configured, the limit is
 enforced before completing the handshake, returning `reject(429)` once the
 peer is at its limit. `request_ip` must return the **real socket peer IP**
 from the TCP connection, or `Error(Nil)` when the server cannot determine
 it — all such connections share a single `"unknown"` limiter bucket, so
 they are limited collectively rather than admitted unchecked. Forwarded
 headers such as `X-Forwarded-For` must
 **not** be trusted or parsed, because clients can set them and would
 otherwise spoof their address to bypass the limit. Behind a trusted
 reverse proxy, all connections share the proxy's IP — resolve the real
 client IP at the proxy layer. See the WebSocket transport guide.

 When `beryl.with_max_connections` is configured, a node-wide ceiling on
 concurrent connections across all IPs is likewise enforced with
 `reject(429)` before allocating any long-lived socket/runtime state. The
 two limits compose: a connection must be under both to be admitted. The
 node-wide ceiling bounds total resource use when a per-IP limit alone
 cannot (many distributed source addresses / IPv6 rotation). It is enforced
 per BEAM node, so across a load-balanced cluster the effective ceiling
 scales with the node count — use the load balancer's own controls for a
 cluster-wide cap.

```gleam
pub fn upgrade(
  request: request.Request(a),
  sockets: beryl.Sockets,
  config: TransportConfig(a),
  request_ip: fn(request.Request(a)) -> Result(String, Nil),
  reject: fn(Int) -> response.Response(b),
  accept: fn(List(#(String, String)), beryl.ConnectionPermit) -> response.Response(b),
  next: fn() -> response.Response(b)
) -> response.Response(b)
```

### `with_allow_all_origins`

Disable `Origin` checking, allowing WebSocket upgrades from any origin.

 This is an explicit opt-out of the default `origin.SameOrigin` CSWSH
 protection. Only use it for sockets that do not rely on ambient browser
 credentials (cookies, sessions) for authorization, or that authenticate
 every message independently. For cookie/session-authenticated apps, prefer
 the default `SameOrigin` policy or `with_allowed_origins`.

```gleam
pub fn with_allow_all_origins(TransportConfig(a)) -> TransportConfig(a)
```

### `with_allowed_origins`

Restrict WebSocket upgrades to requests whose `Origin` header exactly
 matches one of the given values.

 This replaces the default `origin.SameOrigin` policy with an
 `origin.AllowList`. Values are matched exactly against the full `Origin`
 header, including scheme and host (and port when present), such as
 `"https://app.example.com"`. Missing or non-matching origins are rejected
 with `403 Forbidden` before the WebSocket handshake.

 Prefer this over `with_allow_all_origins` when you know the exact origins
 that should be allowed (e.g. behind a reverse proxy that rewrites the
 `Host` header, where `SameOrigin` cannot see the public host).

```gleam
pub fn with_allowed_origins(
  TransportConfig(a),
  List(String)
) -> TransportConfig(a)
```

### `with_on_connect`

Set a socket-level connect/authentication callback on the transport config.

 The callback receives the HTTP request before the WebSocket upgrade and
 runs once per socket. Return `Ok(metadata)` to allow the connection and
 seed `ConnectSeed.metadata` — an ordered list of string pairs delivered to
 the app's `init` via `ConnectInfo.seed` — or `Error(ConnectRejected)` to
 reject the connection with a 403 Forbidden response before any topic
 join occurs.

 Callback order and duplicate keys are preserved verbatim in
 `ConnectSeed.metadata`; transports never log metadata values.

```gleam
pub fn with_on_connect(
  TransportConfig(a),
  fn(request.Request(a)) -> Result(List(#(String, String)), ConnectError)
) -> TransportConfig(a)
```
