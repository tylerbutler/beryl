---
title: WebSocket Transport
description: Connect browsers and other clients to a Beryl sockets system with the Mist transport.
---

Beryl provides a WebSocket transport layer that integrates directly with [Mist](https://hexdocs.pm/mist/). `beryl_ewe` mirrors the same connect-metadata model and overall transport flow, but this guide uses `beryl_mist` examples.

## Basic setup

Start a `beryl.Sockets` system, then hand that handle to the Mist transport.

```gleam
import beryl
import beryl/event as event
import beryl_mist as mist_transport
import beryl/wire
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response as response
import gleam/http/response.{type Response}
import mist

fn init(_info: event.ConnectInfo(Nil)) -> #(Nil, List(event.Effect)) {
  #(Nil, [])
}

fn update(model: Nil, _event: event.Input(Nil)) -> event.Next(Nil, Nil) {
  event.Next(model, [])
}

pub fn main() {
  let assert Ok(sockets) =
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: init,
      update: update,
    )

  mist_transport.handler(
    sockets,
    mist_transport.default_config("/socket/websocket"),
    http_handler,
  )
  |> mist.new
  |> mist.port(8000)
  |> mist.start
}

fn http_handler(_req: Request(mist.Connection)) -> Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}
```

The transport upgrades matching WebSocket requests, assembles `event.ConnectInfo`, and forwards frames into your `init` / `update` app. For the routing model itself, see [App-Side Dispatch](/guides/dispatch/).

:::tip[Phoenix JS clients]
Phoenix JS connects to `/socket/websocket` by default when you write `new Socket("/socket", ...)`, so set the Mist transport path to match.
:::

## Authentication

Use `with_on_connect` to authenticate a connection before upgrading. The callback runs once per socket and returns either connect metadata or `ConnectRejected`.

```gleam
let config =
  mist_transport.default_config("/socket/websocket")
  |> mist_transport.with_on_connect(fn(req: Request(mist.Connection)) {
    case validate_token(req) {
      Ok(user_id) -> Ok([#("user_id", user_id)])
      Error(_) -> Error(mist_transport.ConnectRejected)
    }
  })

use <- mist_transport.upgrade(req, sockets, config)
```

Returning `Error(mist_transport.ConnectRejected)` sends HTTP 403 before the WebSocket handshake.

### Origin validation and CSWSH

Browsers include cookies on WebSocket handshakes. If your socket authentication relies on ambient browser credentials, validate the `Origin` header to prevent Cross-Site WebSocket Hijacking.

```gleam
let config =
  mist_transport.default_config("/socket/websocket")
  |> mist_transport.with_allowed_origins(["https://app.example.com"])
  |> mist_transport.with_on_connect(fn(req: Request(mist.Connection)) {
    validate_cookie_session(req)
  })
```

The default policy is `SameOrigin`. Use `with_allow_all_origins` only when you intentionally opt out of browser-origin checks.

### Seeding connect metadata

`with_on_connect` returns `List(#(String, String))`, not application model state. Those key-value pairs become `ConnectSeed.metadata`, and `init` decides how to turn them into your typed socket model.

```gleam
import beryl/event as event
import gleam/list
import gleam/result

pub type Model {
  Model(user_id: String)
}

fn init(info: event.ConnectInfo(Nil)) -> #(Model, List(event.Effect)) {
  let user_id =
    list.key_find(info.seed.metadata, "user_id")
    |> result.unwrap("anonymous")
  #(Model(user_id: user_id), [])
}
```

`ConnectInfo.seed` also includes the request path, query parameters, and headers seen during the upgrade.

## Direct upgrade

If you want to handle path matching yourself, use `upgrade_connection` directly.

```gleam
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response as response
import gleam/http/response.{type Response}

fn handle_request(req, sockets) -> Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["ws"] -> mist_transport.upgrade_connection(req, sockets)
    _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}
```

`upgrade_connection` does **not** run the configured `with_on_connect` callback and seeds empty connect metadata, so run your own checks first if you need them.

## Wire protocol

`wire.phoenix_codec()` keeps Phoenix-compatible JSON array frames:

```json
[join_ref, ref, topic, event, payload]
```

Applications can pass a custom codec to `beryl.config(codec)` if they want a different framing.

## Connection lifecycle

1. the client opens a WebSocket to the configured path,
2. origin policy is checked,
3. `with_on_connect` runs, optionally rejecting with HTTP 403 or seeding metadata,
4. the transport creates a socket id and calls your `init`,
5. clients send `phx_join` and message frames,
6. the runtime delivers `event.Join`, `event.Message`, `event.Binary`, `event.Info`, and `event.Closed` into your `update`,
7. when a topic or socket ends, the runtime delivers `event.Closed` for every joined topic and the transport closes the connection.

If the runtime crashes or restarts, the Mist transport notices and closes the affected connections instead of leaving zombie sockets open.

## Heartbeats

Clients should send heartbeat messages periodically to stay connected:

```json
[null, "ref_123", "phoenix", "heartbeat", {}]
```

Configure heartbeat timing on the Beryl config:

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_heartbeat(
    interval_ms: 30_000,
    timeout_ms: 60_000,
  )
```

`interval_ms` is advisory for clients. `timeout_ms` is the server-side silence window.

## Rate limiting

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 5, burst: 10)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
```

| Limiter | Scope |
|---------|-------|
| `message_rate` | Per socket |
| `join_rate` | Per socket |
| `channel_rate` | Per socket plus topic |

## Connection limits

Cap concurrent connections per client IP with `with_max_connections_per_ip` and across the whole node with `with_max_connections`.

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_max_connections_per_ip(max_connections: 5)
  |> beryl.with_max_connections(max_connections: 10_000)
```

When a peer is already over the limit, the transport rejects the upgrade with HTTP 429 before allocating long-lived socket state.

## Next steps

- [Authentication](/guides/authentication/) — a complete token-verification flow
- [Error Handling](/guides/error-handling/) — join rejection, malformed frames, and client-visible error shapes
- [Supervision](/guides/supervision/) — what happens when the runtime stops or restarts
