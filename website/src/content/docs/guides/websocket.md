---
title: WebSocket Transport
---

beryl provides a WebSocket transport layer that integrates directly with [Mist](https://hexdocs.pm/mist/) for handling browser client connections.

## Basic setup

The simplest way to add WebSocket support is with `mist_transport.upgrade`:

```gleam
import beryl
import beryl/transport/mist as mist_transport
import gleam/bytes_tree
import gleam/http/request
import gleam/http/request.{type Request}
import gleam/http/response
import mist

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
  case request.path_segments(req) {
    [] -> response.new(200) |> response.set_body(mist.Bytes(bytes_tree.new()))
    _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}
```

The `upgrade` function checks if the request path matches, performs the WebSocket upgrade, and wires the connection to the beryl coordinator.

:::tip[Phoenix JS clients]
The Phoenix JS client (`new Socket("/socket", ...)`) connects to `/socket/websocket` by default — it appends `/websocket` to the path you pass. Configure the transport path to match:

```gleam
// Matches Phoenix JS: new Socket("/socket", ...)
mist_transport.default_config("/socket/websocket")
```

Raw WebSocket clients connect directly to the configured path with no suffix appended.
:::

## Authentication

Use `with_on_connect` to authenticate connections before upgrading:

```gleam
let config =
  mist_transport.default_config("/socket/websocket")
  |> mist_transport.with_on_connect(fn(req: Request(mist.Connection)) {
    // Check auth token, session, etc.
    case validate_token(req) {
      Ok(_user) -> Ok(Nil)    // Allow connection
      Error(_) -> Error(Nil)  // Reject with 403
    }
  })

use <- mist_transport.upgrade(req, channels, config)
```

Returning `Error(Nil)` sends an HTTP 403 before the WebSocket upgrade. See [Connection-level authentication rejection](/guides/error-handling#connection-level-authentication-rejection) for the client-visible error shape and [Authentication failures](/troubleshooting#authentication-failures) for diagnosis steps.

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
let config = beryl.Config(
  ..beryl.config(wire.phoenix_codec()),
  heartbeat_interval_ms: 30_000,  // Client sends every 30s
  heartbeat_timeout_ms: 60_000,   // Server evicts after 60s silence
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

## Next steps

- [Error Handling guide](/guides/error-handling/) — rejected joins, malformed frames, and client-visible error shapes
- [Supervision guide](/guides/supervision/) — supervised startup for production so a coordinator crash doesn't take down the whole transport
- [Troubleshooting](/troubleshooting/) — symptom-first diagnosis for connection, join, and message delivery failures
