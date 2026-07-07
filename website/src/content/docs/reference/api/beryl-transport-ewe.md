---
title: beryl/transport/ewe
description: Ewe WebSocket Transport - Direct Ewe integration for beryl
---

Ewe WebSocket Transport - Direct Ewe integration for beryl

 This module provides the bridge between Ewe's native WebSocket handling
 and the beryl coordinator using Ewe request and response types directly.

 It mirrors the [`beryl/transport/mist`](./mist.html) module: the two
 transports expose the same config-builder and handler API, so an integrator
 can run beryl channels on either web server by choosing the matching
 transport module.

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

Configuration for the Ewe WebSocket transport

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
 regular HTTP from a single Ewe listener.

 The returned function inspects each request and routes it:
 - WebSocket upgrade requests matching the configured socket path are handed
   to [`upgrade`](#upgrade) (which also runs any `on_connect` callback).
 - Everything else — non-upgrade requests, or upgrades to a different path —
   falls through to `http_fallback`.

 This removes the boilerplate upgrade guard integrators would otherwise write
 by hand:

 ```gleam
 ewe_transport.handler(channels, ewe_transport.default_config("/socket"), http_handler)
 |> ewe.new
 |> ewe.listening(port: 8000)
 |> ewe.start
 ```

```gleam
pub fn handler(
  beryl.Channels,
  TransportConfig(a),
  fn(request.Request(http1.Connection)) -> response.Response(ewe.ResponseBody)
) -> fn(request.Request(http1.Connection)) -> response.Response(ewe.ResponseBody)
```

### `upgrade`

Upgrade a request to WebSocket if it matches the configured path

 Usage in your Ewe handler:
 ```gleam
 fn handle_request(req: Request(Connection), channels: Channels) -> Response(ResponseBody) {
   use <- ewe_transport.upgrade(req, channels, ewe_transport.default_config("/socket"))
   // Fall through to regular HTTP routing
   case request.path_segments(req) {
     [] -> index_page()
     _ -> response.new(404) |> response.set_body(ewe.Empty)
   }
 }
 ```

 ## Path matching

 The request path is normalised by re-joining its segments as
 `"/" <> string.join(segments, "/")` and compared for exact equality with
 `config.path`. Because the normalised path never has a trailing slash, a
 config path written with a trailing slash (e.g. `"/socket/"`) will never
 match. Configure the path without a trailing slash (e.g. `"/socket"`).

```gleam
pub fn upgrade(
  request.Request(http1.Connection),
  beryl.Channels,
  TransportConfig(a),
  fn() -> response.Response(ewe.ResponseBody)
) -> response.Response(ewe.ResponseBody)
```

### `upgrade_connection`

Alternative: upgrade any request to WebSocket (caller handles path matching)

 Note: This function does not invoke the `on_connect` callback from
 `TransportConfig`. Sockets upgraded this way start with empty (`Nil`)
 assigns. If you need authentication or seeded assigns, either use `upgrade`
 with a full config or call your auth check before this function.

```gleam
pub fn upgrade_connection(
  request.Request(http1.Connection),
  beryl.Channels
) -> response.Response(ewe.ResponseBody)
```

### `with_allowed_origins`

Restrict WebSocket upgrades to requests with an allowed `Origin` header.

 Values are matched exactly against the full Origin header value, including
 scheme and host (and port when present), such as
 `"https://app.example.com"`. When configured, missing or non-matching
 origins are rejected with `403 Forbidden` before the WebSocket handshake.

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
  fn(request.Request(http1.Connection)) -> Result(b, ConnectError)
) -> TransportConfig(b)
```
