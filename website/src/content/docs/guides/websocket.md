---
title: Use the Mist WebSocket Transport
description: Upgrade Mist requests to WebSockets, authenticate connections, and use the Phoenix wire protocol.
---

beryl provides a WebSocket transport for
[Mist](https://hexdocs.pm/mist/) browser connections.

## Add WebSocket upgrades

Use `mist_transport.upgrade` to add WebSocket support:

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

The `upgrade` function checks the request path. It upgrades a matching request
and connects it to the beryl runtime.

The transport works with both Beryl APIs. A handle from
`channel.child_spec` is the same `beryl.Sockets` type as one from
`beryl.child_spec`, so the setup is identical for both.

:::tip[Phoenix JS clients]
The Phoenix JS client (`new Socket("/socket", ...)`) adds `/websocket` to the
path. Configure the transport to use `/socket/websocket`:

```gleam
// Matches Phoenix JS: new Socket("/socket", ...)
server.default_config("/socket/websocket")
```

Raw WebSocket clients connect directly to the configured path with no suffix appended.
:::

## Authenticate before the upgrade

Use `with_on_connect` to authenticate a connection before the upgrade. It is
similar to Phoenix `UserSocket.connect/3`. The hook runs once for each socket
before any channel join. It can reject the connection.

```gleam
let ws_config =
  server.default_config("/socket/websocket")
  |> server.with_on_connect(fn(req: Request(mist.Connection)) {
    // Check auth token, session, etc.
    case validate_token(req) {
      Ok(_user) -> Ok([])                        // Allow; no connect metadata
      Error(_) -> Error(server.ConnectRejected)  // Reject with 403
    }
  })

use <- mist_transport.upgrade(req, channels, ws_config)
```

Return `Error(server.ConnectRejected)` to send HTTP 403 before the WebSocket
upgrade. See
[Reject a connection during authentication](/guides/error-handling#reject-a-connection-during-authentication)
for the client error. See
[Authentication failures](/troubleshooting#authentication-failures) for
diagnostic steps.

### Block Cross-Site WebSocket Hijacking (CSWSH)

Browsers include cookies on WebSocket handshakes. If your socket authentication
uses cookies, a malicious site can open a WebSocket to your application from a
victim's browser unless you validate the `Origin` header. This is Cross-Site
WebSocket Hijacking (CSWSH).

Use `with_allowed_origins` to allow only your application origins. Values match
the full `Origin` header exactly: scheme, host, and port when present.

```gleam
let ws_config =
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

### Read request data from `ConnectSeed`

`on_connect` accepts or rejects the upgrade. The transport puts the request
path, query parameters, and headers in a `ConnectSeed`, and your `init`
function receives it as `ConnectInfo.seed`:

| Field | Type | Description |
| --- | --- | --- |
| `path` | `String` | The request path the client connected to. |
| `query` | `List(#(String, String))` | Parsed query parameters. |
| `headers` | `List(#(String, String))` | Request headers. |
| `metadata` | `List(#(String, String))` | Whatever `on_connect` returned. |

`on_connect` does not return `Ok(Nil)`. It returns `Ok(metadata)`, a
list of string pairs that reaches `init` as `seed.metadata`. Resolve the identity once during the handshake and return it as metadata.
Then `init` can read it instead of decoding the request again:

```gleam
let ws_config =
  server.default_config("/socket/websocket")
  |> server.with_on_connect(fn(req: Request(mist.Connection)) {
    // Validate once; reject the whole connection on failure.
    case validate_token(req) {
      Ok(user_id) -> Ok([#("user_id", user_id)])
      Error(_) -> Error(server.ConnectRejected) // Reject with 403
    }
  })
```

```gleam
// init reads what on_connect already resolved. It does not decode again.
beryl.child_spec(
  config,
  init: fn(info: socket.ConnectInfo(Msg)) {
    let user_id =
      list.key_find(info.seed.metadata, "user_id")
      |> result.unwrap("anonymous")
    #(Model(user_id: user_id), [])
  },
  update: update,
)
```

Return `Ok([])` when there is nothing to pass on. The list keeps the order
`on_connect` produced and keeps duplicate keys, so `list.key_find` returns the
first pair for a key. Values are strings only: encode anything richer, such as
a list of roles, into one. Transports never log metadata values, but the seed
reaches every join callback on that socket, so put an identity there rather
than a secret.

With the channel layer, the same seed arrives in every handler's `join`
callback as `channel.JoinContext.seed`, metadata included; there is no
app-level `init`. See
[Authentication with `beryl/channel`](/guides/authentication/#use-authentication-with-berylchannel).

:::tip[Troubleshooting connections]
If clients cannot connect, see [Clients cannot connect at all](/troubleshooting#clients-cannot-connect-at-all) for path mismatch, reverse proxy, and upgrade header checks.
:::

## Choose the wire protocol

Pass `wire.phoenix_codec()` to `beryl.config` to use the Phoenix JSON array format:

```json
[join_ref, ref, topic, event, payload]
```

Applications can pass a custom codec to `beryl.config(codec)`. The codec can
use another text or binary message format. The transport sends each outbound
frame as the type that the codec returns.

`wire.phoenix_codec()` uses Beryl's Phoenix wire implementation and adds no
dependencies. The public `beryl/wire/codec.Codec` API and wire format are
stable, so applications can supply a codec for another message format.

| Field | JSON type | Description |
|-------|------|-------------|
| `join_ref` | `string \| null` | Reference from the join (for reply routing) |
| `ref` | `string \| null` | Unique message reference (for reply matching) |
| `topic` | `string` | Topic name (e.g., `"room:lobby"`) |
| `event` | `string` | Event name (e.g., `"phx_join"`, `"new_message"`) |
| `payload` | `any` | JSON payload |

### Phoenix protocol events

| Event | Direction | Purpose |
|-------|-----------|-------------|
| `phx_join` | Client -> Server | Join a channel |
| `phx_leave` | Client -> Server | Leave a channel |
| `heartbeat` | Client -> Server | Keepalive ping |
| `phx_reply` | Server -> Client | Reply to a client message |
| `phx_error` | Server -> Client | Error notification |
| `phx_close` | Server -> Client | Channel closed |

### Join request and reply

Client sends:
```json
["1", "1", "room:lobby", "phx_join", {"user": "alice"}]
```

Server replies:
```json
["1", "1", "room:lobby", "phx_reply", {"status": "ok", "response": {}}]
```

## Connection steps

1. Client connects via WebSocket to the configured path
2. The `on_connect` callback runs, if configured. Rejection returns HTTP 403.
3. The transport connection process builds the `ConnectSeed`, generates a
   unique socket ID, and starts a socket actor. The router admits and monitors
   that actor, which runs your `init`.
4. The client sends `phx_join` messages to subscribe to topics. Each one
   arrives at `update` as a `Join` event.
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

## Limit inbound traffic

Protect against flood attacks with built-in rate limiting:

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_frame_rate(per_second: 150, burst: 300)
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 5, burst: 10)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
```

| Limiter | Applies to | Enforced at |
|---------|-------|----------|
| `frame_rate` | Per connection, all complete frames | Transport, before decode |
| `message_rate` | Per socket, decoded non-join traffic | Runtime |
| `join_rate` | Per socket, joins | Runtime |
| `channel_rate` | Per socket+topic | Runtime |
| `topic_rates` | Topics matching a pattern; overrides `channel_rate` | Runtime |

Frame and message buckets are independent. Malformed frames and joins consume
frame tokens; joins do not consume message tokens.

## Limit connections by IP address

Cap both the connection-attempt rate and the number of concurrent connections
a single client IP may hold. Both controls default to unlimited.

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_connection_rate_per_ip(per_second: 2, burst: 5)
  |> beryl.with_max_connections_per_ip(max_connections: 5)
```

When a peer reaches either limit, Mist rejects the upgrade with
`429 Too Many Requests` before the handshake. A closed connection releases its
concurrent capacity. The per-IP rate bucket remains after reconnects and app
runtime restarts. Thus, a reconnect does not provide a new rate allowance.

### Reverse proxies and `X-Forwarded-For`

Both controls use the **socket peer IP**, which is the TCP address that Mist
accepts. beryl does not trust forwarded headers such as `X-Forwarded-For`.
Clients can forge these headers and bypass the limit.

This affects beryl when it runs **behind a reverse proxy or
load balancer** (nginx, HAProxy, a cloud LB, etc.): every connection arrives
from the proxy's IP, so a per-IP limit sees all clients as one address and
throttles them together. In that setup:

- Enforce per-IP limits at the proxy layer, where the real client IP is known, or
- Terminate connections directly (no intermediary) if you want beryl's built-in
  per-IP limit to apply to individual clients.

Beryl does not have a trusted-proxy option that reads a client IP from a
forwarded header only when the immediate peer is trusted. Treat
`X-Forwarded-For` as untrusted input.

## Next steps

- [Error Handling guide](/guides/error-handling/): rejected joins, malformed frames, and client errors
- [Channels guide](/guides/channels/): use the transport with the channel layer
- [Supervision guide](/guides/supervision/): understand runtime restarts and shutdown
- [Troubleshooting](/troubleshooting/): diagnose connection, join, and message delivery failures
