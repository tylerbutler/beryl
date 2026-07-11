---
title: beryl/transport/mist
description: Mist WebSocket Transport - Direct Mist integration for beryl
---

Mist WebSocket Transport - Direct Mist integration for beryl

 This module provides the bridge between Mist's native WebSocket handling
 and the beryl coordinator using Mist request and response types directly.

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

### `OriginPolicy`

Policy for validating the browser `Origin` header before a WebSocket
 upgrade completes.

 The `Origin` check is the primary defence against Cross-Site WebSocket
 Hijacking (CSWSH): a browser attaches ambient cookies/session credentials
 to a WebSocket handshake regardless of which site initiated it, so a socket
 that authenticates from those credentials must reject upgrades that
 originate from other sites.

 In every policy, a request with **no** `Origin` header is allowed: browsers
 always send `Origin` on WebSocket handshakes, so an absent header signals a
 non-browser client (native app, server-to-server, CLI) that is not subject
 to the browser same-origin model and cannot be tricked into a cross-site
 upgrade. The one exception is [`AllowList`](#OriginPolicy), which requires a
 matching `Origin` and therefore rejects absent ones.

```gleam
pub type OriginPolicy {
  SameOrigin
  AllowList(List(String))
  AllowAll
}
```

#### Constructors

##### `SameOrigin`

Allow an upgrade only when the request `Origin` authority (host plus any
 port, with the scheme stripped) matches the request `Host` authority.
 This is the default and rejects cross-site upgrades before the handshake.

 A malformed or opaque `Origin` (e.g. `null` from a sandboxed iframe, or a
 value with no host) is rejected. Comparison is over the full `host:port`
 authority, so a non-default port must match on both sides.

 Behind a reverse proxy this compares against the `Host` header as the app
 sees it: ensure the proxy forwards the public `Host` unchanged, or use
 [`AllowList`](#OriginPolicy) with the public origins instead. Forwarded
 headers such as `X-Forwarded-Host` are not trusted, because clients can
 spoof them.

##### `AllowList(List(String))`

Allow an upgrade only when the request `Origin` header matches one of the
 listed values exactly (including scheme, host, and any port), such as
 `"https://app.example.com"`. Requests without an `Origin` header, or with
 a non-matching one, are rejected.

##### `AllowAll`

Allow every upgrade regardless of `Origin`. This is an explicit opt-out
 of CSWSH protection: only use it for sockets that do not rely on ambient
 browser credentials (or that authenticate every message independently).

### `TransportConfig`

Configuration for the Mist WebSocket transport

 The `assigns` type parameter is the socket-level state produced by the
 `on_connect` hook. It defaults to `Nil` when no hook is configured.

```gleam
pub type TransportConfig(a)
```

## Functions

### `default_config`

Create a default transport config with no connect hook.

 The resulting config seeds `Nil` assigns and applies the
 [`SameOrigin`](#OriginPolicy) origin policy, which rejects cross-site
 WebSocket upgrades before the handshake (CSWSH protection). Same-origin
 upgrades and non-browser clients (no `Origin` header) are admitted without
 configuration.

 Add `with_on_connect` to authenticate connections and/or seed initial
 assigns. Use `with_allowed_origins` to pin an explicit allow-list, or
 `with_allow_all_origins` to opt out of origin checking entirely.

```gleam
pub fn default_config(String) -> TransportConfig(Nil)
```

### `handler`

Build a combined request handler that serves both WebSocket channels and
 regular HTTP from a single Mist listener.

 The returned function inspects each request and routes it:
 - WebSocket upgrade requests matching the configured socket path are handed
   to [`upgrade`](#upgrade) (which also runs any `on_connect` callback).
 - Everything else — non-upgrade requests, or upgrades to a different path —
   falls through to `http_fallback`.

 This removes the boilerplate upgrade guard integrators would otherwise write
 by hand:

 ```gleam
 mist_transport.handler(channels, mist_transport.default_config("/socket"), http_handler)
 |> mist.new
 |> mist.port(8000)
 |> mist.start
 ```

```gleam
pub fn handler(
  beryl.Channels,
  TransportConfig(a),
  fn(request.Request(http.Connection)) -> response.Response(mist.ResponseData)
) -> fn(request.Request(http.Connection)) -> response.Response(mist.ResponseData)
```

### `upgrade`

Upgrade a request to WebSocket if it matches the configured path

 Usage in your Mist handler:
 ```gleam
 fn handle_request(req: Request(Connection), channels: Channels) -> Response(ResponseData) {
   use <- mist_transport.upgrade(req, channels, mist_transport.default_config("/socket"))
   // Fall through to regular HTTP routing
   case request.path_segments(req) {
     [] -> index_page()
     _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
   }
 }
 ```

 ## Path matching

 The request path is normalised by re-joining its segments as
 `"/" <> string.join(segments, "/")` and compared for exact equality with
 `config.path`. Because the normalised path never has a trailing slash, a
 config path written with a trailing slash (e.g. `"/socket/"`) will never
 match. Configure the path without a trailing slash (e.g. `"/socket"`).

 ## Connection limits

 When `beryl.with_max_connections_per_ip` is configured, this transport
 enforces the limit before completing the handshake and returns `429 Too
 Many Requests` once the peer is at its limit. Enforcement uses the **real
 socket peer IP** from the TCP connection; forwarded headers such as
 `X-Forwarded-For` are **not** trusted or parsed, because clients can set
 them and would otherwise spoof their address to bypass the limit. Behind a
 trusted reverse proxy, all connections share the proxy's IP — resolve the
 real client IP at the proxy layer. See the WebSocket transport guide.

 When `beryl.with_max_connections` is configured, this transport also
 enforces a node-wide ceiling on concurrent connections across all IPs,
 likewise returning `429` and rejecting the upgrade before allocating any
 long-lived channel/coordinator state. The two limits compose: a connection
 must be under both to be admitted. The node-wide ceiling bounds total
 resource use when a per-IP limit alone cannot (many distributed source
 addresses / IPv6 rotation). It is enforced per BEAM node, so across a
 load-balanced cluster the effective ceiling scales with the node count —
 use the load balancer's own controls for a cluster-wide cap.

```gleam
pub fn upgrade(
  request.Request(http.Connection),
  beryl.Channels,
  TransportConfig(a),
  fn() -> response.Response(mist.ResponseData)
) -> response.Response(mist.ResponseData)
```

### `upgrade_connection`

Alternative: upgrade any request to WebSocket (caller handles path matching)

 Note: This function does not invoke the `on_connect` callback from
 `TransportConfig`. Sockets upgraded this way start with empty (`Nil`)
 assigns. If you need authentication or seeded assigns, either use `upgrade`
 with a full config or call your auth check before this function.

```gleam
pub fn upgrade_connection(
  request.Request(http.Connection),
  beryl.Channels
) -> response.Response(mist.ResponseData)
```

### `with_allow_all_origins`

Disable `Origin` checking, allowing WebSocket upgrades from any origin.

 This is an explicit opt-out of the default [`SameOrigin`](#OriginPolicy)
 CSWSH protection and restores the pre-1.0 allow-all behaviour. Only use it
 for sockets that do not rely on ambient browser credentials (cookies,
 sessions) for authorization, or that authenticate every message
 independently. For cookie/session-authenticated apps, prefer the default
 `SameOrigin` policy or `with_allowed_origins`.

```gleam
pub fn with_allow_all_origins(TransportConfig(a)) -> TransportConfig(a)
```

### `with_allowed_origins`

Restrict WebSocket upgrades to requests whose `Origin` header exactly
 matches one of the given values.

 This replaces the default [`SameOrigin`](#OriginPolicy) policy with an
 [`AllowList`](#OriginPolicy). Values are matched exactly against the full
 `Origin` header, including scheme and host (and port when present), such as
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
 runs once per socket. Return `Ok(assigns)` to allow the connection and seed
 initial socket assigns that channels can read at join time, or
 `Error(ConnectRejected)` to reject the connection with a 403 Forbidden
 response before any channel join occurs.

```gleam
pub fn with_on_connect(
  TransportConfig(a),
  fn(request.Request(http.Connection)) -> Result(b, ConnectError)
) -> TransportConfig(b)
```
