---
title: WebSocket Transport
---

beryl provides a WebSocket transport layer that integrates with [Wisp](https://github.com/gleam-wisp/wisp) for handling browser client connections.

## Basic setup

The simplest way to add WebSocket support is with `websocket.upgrade`:

```gleam
import beryl
import beryl/transport/websocket
import wisp

fn handle_request(
  req: wisp.Request,
  channels: beryl.Channels,
) -> wisp.Response {
  // Upgrade /socket requests to WebSocket
  use <- websocket.upgrade(
    req,
    channels.coordinator,
    websocket.default_config("/socket"),
  )

  // Non-WebSocket requests fall through here
  case wisp.path_segments(req) {
    [] -> wisp.ok()
    _ -> wisp.not_found()
  }
}
```

The `upgrade` function checks if the request path matches, performs the WebSocket upgrade, and wires the connection to the beryl coordinator.

## Authentication

Use `with_on_connect` to authenticate connections before upgrading:

```gleam
let config =
  websocket.default_config("/socket")
  |> websocket.with_on_connect(fn(req: wisp.Request) {
    // Check auth token, session, etc.
    case validate_token(req) {
      Ok(_user) -> Ok(Nil)    // Allow connection
      Error(_) -> Error(Nil)  // Reject with 403
    }
  })

use <- websocket.upgrade(req, channels.coordinator, config)
```

## Direct upgrade

If you handle path matching yourself, use `upgrade_connection` directly:

```gleam
fn handle_request(req, channels) -> wisp.Response {
  case wisp.path_segments(req) {
    ["ws"] -> websocket.upgrade_connection(req, channels.coordinator)
    _ -> wisp.not_found()
  }
}
```

Note: `upgrade_connection` does not invoke the `on_connect` callback. Run your own auth check before calling it.

## Wire protocol

beryl uses the Phoenix wire protocol — a JSON array format:

```json
[join_ref, ref, topic, event, payload]
```

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
  ..beryl.default_config(),
  heartbeat_interval_ms: 30_000,  // Client sends every 30s
  heartbeat_timeout_ms: 60_000,   // Server evicts after 60s silence
)
```

## Rate limiting

Protect against flood attacks with built-in rate limiting:

```gleam
let config =
  beryl.default_config()
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 5, burst: 10)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
```

| Limiter | Scope | Description |
|---------|-------|-------------|
| `message_rate` | Per socket | Total messages per second across all topics |
| `join_rate` | Per socket | Join attempts per second |
| `channel_rate` | Per socket+topic | Messages per second on a single topic |
