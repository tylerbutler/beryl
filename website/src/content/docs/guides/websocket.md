---
title: WebSocket Transport
---

beryl provides a WebSocket transport layer that integrates directly with [Mist](https://hexdocs.pm/mist/) for handling browser client connections.

## Basic setup

The simplest way to add WebSocket support is with `mist_transport.upgrade`:

```gleam
import beryl
import beryl/transport/server
import beryl_mist as mist_transport
import gleam/bytes_tree
import gleam/http/request
import gleam/http/request.{type Request}
import gleam/http/response
import mist

fn handle_request(
  req: Request(mist.Connection),
  channels: beryl.Sockets,
) -> response.Response(mist.ResponseData) {
  // Upgrade /socket/websocket requests to WebSocket
  use <- mist_transport.upgrade(
    req,
    channels,
    server.default_config("/socket/websocket"),
  )

  // Non-WebSocket requests fall through here
  case request.path_segments(req) {
    [] -> response.new(200) |> response.set_body(mist.Bytes(bytes_tree.new()))
    _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}
```

The `upgrade` function checks if the request path matches, performs the WebSocket upgrade, and wires the connection to the beryl runtime.

:::tip[Phoenix JS clients]
The Phoenix JS client (`new Socket("/socket", ...)`) connects to `/socket/websocket` by default — it appends `/websocket` to the path you pass. Configure the transport path to match:

```gleam
// Matches Phoenix JS: new Socket("/socket", ...)
server.default_config("/socket/websocket")
```

Raw WebSocket clients connect directly to the configured path with no suffix appended.
:::

## Authentication

Use `with_on_connect` to authenticate connections before upgrading. The hook is
beryl's analogue of Phoenix's `UserSocket.connect/3`: it runs **once per socket**,
before any channel join, and can reject the whole connection.

```gleam
let config =
  server.default_config("/socket/websocket")
  |> server.with_on_connect(fn(req: Request(mist.Connection)) {
    // Check auth token, session, etc.
    case validate_token(req) {
      Ok(_user) -> Ok(Nil)                              // Allow connection
      Error(_) -> Error(server.ConnectRejected)  // Reject with 403
    }
  })

use <- mist_transport.upgrade(req, channels, config)
```

Returning `Error(server.ConnectRejected)` sends an HTTP 403 before the WebSocket upgrade. See [Connection-level authentication rejection](/guides/error-handling#connection-level-authentication-rejection) for the client-visible error shape and [Authentication failures](/troubleshooting#authentication-failures) for diagnosis steps.

### Origin validation and CSWSH

Browsers include cookies on WebSocket handshakes. If your socket authentication
uses cookies, a malicious site can open a WebSocket to your application from a
victim's browser unless you validate the `Origin` header. This is Cross-Site
WebSocket Hijacking (CSWSH).

Use `with_allowed_origins` to allow only your application origins. Values match
the full `Origin` header exactly: scheme, host, and port when present.

```gleam
let config =
  server.default_config("/socket/websocket")
  |> server.with_allowed_origins(["https://app.example.com"])
  |> server.with_on_connect(fn(req: Request(mist.Connection)) {
    validate_cookie_session(req)
  })
```

Requests with missing or non-matching origins are rejected with HTTP 403 before
the WebSocket handshake. Without an explicit allow-list, the default
`SameOrigin` policy rejects cross-site browser handshakes while allowing
non-browser clients that omit `Origin`.

If you cannot use an origin allow-list, avoid cookie-based WebSocket
authentication. Use a token passed explicitly to `on_connect` and reject invalid
tokens before upgrading.

### Connect-time data and the ConnectSeed

`on_connect` is a pure gate — it allows or rejects the upgrade. The request
data itself (path, query parameters, headers) reaches your app separately:
the transport assembles a `ConnectSeed` from the upgrade request and delivers
it to your `init` as `ConnectInfo.seed`. Authenticate once in `on_connect`,
then derive per-socket state from the seed in `init` — no re-auth in any
join:

```gleam
let config =
  server.default_config("/socket/websocket")
  |> server.with_on_connect(fn(req: Request(mist.Connection)) {
    // Validate once; reject the whole connection on failure.
    case validate_token(req) {
      Ok(_) -> Ok(Nil)
      Error(_) -> Error(server.ConnectRejected) // Reject with 403
    }
  })
```

```gleam
// init derives the user from the same request data — no re-auth needed.
beryl.child_spec(
  config,
  init: fn(info: socket.ConnectInfo(Msg)) {
    let user_id =
      list.key_find(info.seed.query, "token")
      |> result.map(decode_user_id)
      |> result.unwrap("anonymous")
    #(Model(user_id: user_id), [])
  },
  update: update,
)
```

:::tip[Troubleshooting connections]
If clients cannot connect, see [Clients cannot connect at all](/troubleshooting#clients-cannot-connect-at-all) for path mismatch, reverse proxy, and upgrade header checks.
:::

## Wire protocol

Pass `wire.phoenix_codec()` to `beryl.config` to use the Phoenix JSON array format:

```json
[join_ref, ref, topic, event, payload]
```

Applications can pass a custom codec to `beryl.config(codec)` to use another text framing or a binary framing. Codec-produced outbound frames are sent as text or binary WebSocket frames according to the codec result.

`wire.phoenix_codec()` uses Beryl's native Phoenix wire implementation, which has no extra dependencies. The public `beryl/wire/codec.Codec` API and wire format are stable, so applications can supply their own codec to `beryl.config` for alternative framings.

| Field | Type | Description |
|-------|------|-------------|
| `join_ref` | `string \| null` | Reference from the join (for reply routing) |
| `ref` | `string \| null` | Unique message reference (for reply matching) |
| `topic` | `string` | Topic name (e.g., `"room:lobby"`) |
| `event` | `string` | Event name (e.g., `"phx_join"`, `"new_message"`) |
| `payload` | `any` | JSON payload |

### System events

| Event | Direction | Description |
|-------|-----------|-------------|
| `phx_join` | Client -> Server | Join a channel |
| `phx_leave` | Client -> Server | Leave a channel |
| `heartbeat` | Client -> Server | Keepalive ping |
| `phx_reply` | Server -> Client | Reply to a client message |
| `phx_error` | Server -> Client | Error notification |
| `phx_close` | Server -> Client | Channel closed |

### Example: join flow

Client sends:
```json
["1", "1", "room:lobby", "phx_join", {"user": "alice"}]
```

Server replies:
```json
["1", "1", "room:lobby", "phx_reply", {"status": "ok", "response": {}}]
```

## Connection lifecycle

1. Client connects via WebSocket to the configured path
2. `on_connect` callback runs (if configured) — reject returns 403
3. Transport generates a unique socket ID, builds the `ConnectSeed`, and announces the socket to the runtime, which calls your `init`
4. Client sends `phx_join` messages to subscribe to topics — each arrives at `update` as a `Join` event
5. Messages are routed through the runtime to `update` as `Message` events
6. On disconnect, `update` receives a `Closed` event for every joined topic

## Heartbeats

Clients should send periodic heartbeat messages to stay connected:

```json
[null, "ref_123", "phoenix", "heartbeat", {}]
```

Configure heartbeat timing in the beryl config:

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_heartbeat(
    timeout_ms: 60_000,  // Server evicts after 60s silence (must be >= 2)
  )
```

## Rate limiting

Protect against flood attacks with built-in rate limiting:

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_frame_rate(per_second: 150, burst: 300)
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 5, burst: 10)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
```

| Limiter | Scope | Enforced |
|---------|-------|----------|
| `frame_rate` | Per connection, all complete frames | Transport edge |
| `message_rate` | Per socket, decoded non-join traffic | Runtime |
| `join_rate` | Per socket, joins | Runtime |
| `channel_rate` | Per socket+topic | Runtime |
| `topic_rates` | Pattern-scoped override of `channel_rate` | Runtime |

Frame and message buckets are independent. Malformed frames and joins consume
frame tokens; joins do not consume message tokens.

## Per-IP connection limits

Cap the number of concurrent connections a single client IP may hold with
`with_max_connections_per_ip`. A value of `0` (the default) means unlimited.

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_max_connections_per_ip(max_connections: 5)
```

When a peer is already at its limit, the Mist transport rejects the new upgrade
with `429 Too Many Requests` before the WebSocket handshake completes. The slot
is released automatically when a connection closes, so disconnecting frees
capacity for that IP.

### Reverse proxies and `X-Forwarded-For`

The limit is enforced on the **real socket peer IP** — the address of the TCP
connection Mist accepts. beryl deliberately does **not** trust or parse
forwarded headers such as `X-Forwarded-For`, because any client can set them and
would otherwise be able to spoof its address and bypass the limit.

This has an important consequence when beryl runs **behind a reverse proxy or
load balancer** (nginx, HAProxy, a cloud LB, etc.): every connection arrives
from the proxy's IP, so a per-IP limit sees all clients as one address and
throttles them collectively. In that topology:

- Enforce per-IP limits at the proxy layer, where the real client IP is known, or
- Terminate connections directly (no intermediary) if you want beryl's built-in
  per-IP limit to apply to individual clients.

A built-in trusted-proxy opt-in (to derive the client IP from a forwarded header
only when the immediate peer is a configured trusted proxy) may be added in a
future release. Until then, treat `X-Forwarded-For` as untrusted input.

## Next steps

- [Error Handling guide](/guides/error-handling/) — rejected joins, malformed frames, and client-visible error shapes
- [Supervision guide](/guides/supervision/) — the built-in runtime supervision and restart semantics
- [Troubleshooting](/troubleshooting/) — symptom-first diagnosis for connection, join, and message delivery failures
