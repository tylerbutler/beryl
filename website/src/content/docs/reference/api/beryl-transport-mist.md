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

 The resulting config seeds `Nil` assigns. Add `with_on_connect` to
 authenticate connections and/or seed initial assigns.

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
