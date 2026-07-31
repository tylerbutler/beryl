---
title: WebSocket Transport
---

beryl serves channels over WebSockets through a transport package. Two are
available and expose the same API:

| Package | Web server |
|---|---|
| `beryl_mist` | [Mist](https://hexdocs.pm/mist/) |
| `beryl_ewe` | [Ewe](https://hexdocs.pm/ewe/) |

This guide uses `beryl_mist`. Every example applies to `beryl_ewe` with
`ewe_transport` substituted for `mist_transport` — the config builders,
`on_connect` hook, origin validation, and handler functions are identical.

## Basic setup

`mist_transport.handler` composes the WebSocket upgrade and your regular HTTP
handler into a single request handler, so it is the shortest path to a working
server:

```gleam
import beryl
import beryl_mist as mist_transport
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response
import mist

pub fn start(channels: beryl.Channels) {
  mist_transport.handler(
    channels,
    mist_transport.default_config("/socket/websocket"),
    handle_http,
  )
  |> mist.new
  |> mist.port(8000)
  |> mist.start
}

fn handle_http(
  req: Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    [] -> response.new(200) |> response.set_body(mist.Bytes(bytes_tree.new()))
    _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}
```

WebSocket upgrades on the configured path go to beryl; everything else falls
through to `handle_http`.

### Driving the upgrade yourself

When you need the upgrade decision inside your own routing — to run middleware
first, or to mount the socket conditionally — use `mist_transport.upgrade`
directly. It matches the request path, performs the upgrade, and calls the
continuation when the path does not match:

```gleam
fn handle_request(
  req: Request(mist.Connection),
  channels: beryl.Channels,
) -> response.Response(mist.ResponseData) {
  // Upgrade /socket/websocket requests to WebSocket
  use <- mist_transport.upgrade(
    req,
    channels,
    mist_transport.default_config("/socket/websocket"),
  )

  // Non-WebSocket requests fall through here
  handle_http(req)
}
```

:::tip[Phoenix JS clients]
The Phoenix JS client (`new Socket("/socket", ...)`) connects to `/socket/websocket` by default — it appends `/websocket` to the path you pass. Configure the transport path to match:

```gleam
// Matches Phoenix JS: new Socket("/socket", ...)
mist_transport.default_config("/socket/websocket")
```

Raw WebSocket clients connect directly to the configured path with no suffix appended.
:::

## Authentication

Use `with_on_connect` to authenticate connections before upgrading. The hook is
beryl's analogue of Phoenix's `UserSocket.connect/3`: it runs **once per socket**,
before any channel join, and can reject the whole connection.

```gleam
let config =
  mist_transport.default_config("/socket/websocket")
  |> mist_transport.with_on_connect(fn(req: Request(mist.Connection)) {
    // Check auth token, session, etc.
    case validate_token(req) {
      Ok(_user) -> Ok(Nil)                              // Allow connection
      Error(_) -> Error(mist_transport.ConnectRejected)  // Reject with 403
    }
  })

use <- mist_transport.upgrade(req, channels, config)
```

Returning `Error(mist_transport.ConnectRejected)` sends an HTTP 403 before the WebSocket upgrade. See [Connection-level authentication rejection](/guides/error-handling/#connection-level-authentication-rejection) for the client-visible error shape and [Authentication failures](/troubleshooting/#authentication-failures) for diagnosis steps.

### Origin validation and CSWSH

Browsers include cookies on WebSocket handshakes. If your socket authentication
uses cookies, a malicious site can open a WebSocket to your application from a
victim's browser unless you validate the `Origin` header. This is Cross-Site
WebSocket Hijacking (CSWSH).

Use `with_allowed_origins` to allow only your application origins. Values match
the full `Origin` header exactly: scheme, host, and port when present.

```gleam
let config =
  mist_transport.default_config("/socket/websocket")
  |> mist_transport.with_allowed_origins(["https://app.example.com"])
  |> mist_transport.with_on_connect(fn(req: Request(mist.Connection)) {
    validate_cookie_session(req)
  })
```

Requests with missing or non-matching origins are rejected with HTTP 403 before
the WebSocket handshake. If you do not configure an allow-list, existing behavior
is unchanged and all origins are accepted.

If you cannot use an origin allow-list, avoid cookie-based WebSocket
authentication. Use a token passed explicitly to `on_connect` and reject invalid
tokens before upgrading.

### Seeding initial assigns

`on_connect` can also return seeded socket-level **assigns** instead of `Nil`.
Whatever value you return in `Ok(assigns)` becomes the socket's initial assigns
and is visible to every channel at join time via `socket.get_assigns`. This lets
you authenticate once at connect and avoid repeating per-socket auth in each
channel's `join`:

```gleam
let config =
  mist_transport.default_config("/socket/websocket")
  |> mist_transport.with_on_connect(fn(req: Request(mist.Connection)) {
    // Validate once, derive socket state, reject on failure.
    case validate_token(req) {
      Ok(user_id) -> Ok(user_id)                       // Seed assigns
      Error(_) -> Error(mist_transport.ConnectRejected) // Reject with 403
    }
  })
```

```gleam
// The channel reads the connect-seeded assigns at join — no re-auth needed.
fn join(_topic, _payload, socket) {
  let user_id = socket.get_assigns(socket)
  channel.JoinOk(reply: None, socket: socket)
}
```

The assigns type returned by `on_connect` should match the channel's `assigns`
type (commonly a record shared across all topics that require the same auth).
When no hook is configured, sockets start with `Nil` assigns.

## Direct upgrade

If you handle path matching yourself, use `upgrade_connection` directly:

```gleam
fn handle_request(req, channels) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["ws"] -> mist_transport.upgrade_connection(req, channels)
    _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}
```

Note: `upgrade_connection` does not invoke the `on_connect` callback. Run your own auth check before calling it.

:::tip[Troubleshooting connections]
If clients cannot connect, see [Clients cannot connect at all](/troubleshooting/#clients-cannot-connect-at-all) for path mismatch, reverse proxy, and upgrade header checks.
:::

## Wire protocol

Pass `wire.phoenix_codec()` to `beryl.config` to use the Phoenix JSON array format:

```json
[join_ref, ref, topic, event, payload]
```

Applications can pass a custom codec to `beryl.config(codec)` to use another text framing or a binary framing. Codec-produced outbound frames are sent as text or binary WebSocket frames according to the codec result.

`wire.phoenix_codec()` uses beryl's native Phoenix wire implementation, which has no extra dependencies. The public `beryl/wire/codec.Codec` API and wire format are stable, so applications can supply their own codec to `beryl.config` for alternative framings.

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
3. Transport generates a unique socket ID and registers with the coordinator
4. Client sends `phx_join` messages to subscribe to topics
5. Messages are routed through the coordinator to channel handlers
6. On disconnect, the coordinator runs `terminate` on all joined channels

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
    interval_ms: 30_000,  // Client-advisory ping cadence (server does not read it)
    timeout_ms: 60_000,   // Server evicts after 60s silence (must be >= 2)
  )
```

## Rate limiting

Protect against flood attacks with built-in rate limiting:

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 5, burst: 10)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
```

| Limiter | Scope | Description |
|---------|-------|-------------|
| `message_rate` | Per socket | Total messages per second across all topics |
| `join_rate` | Per socket | Join attempts per second |
| `channel_rate` | Per socket+topic | Messages per second on a single topic |

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
- [Supervision guide](/guides/supervision/) — supervised startup for production so a coordinator crash doesn't take down the whole transport
- [Troubleshooting](/troubleshooting/) — symptom-first diagnosis for connection, join, and message delivery failures
