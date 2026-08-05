---
title: Reference
description: Module map, wire protocol, broadcast cheatsheet, and client compatibility for beryl.
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable, features may be removed in minor releases, and quality should not be considered production-ready. We welcome usage and feedback in the meantime! See the [Stability policy](#pre-10-stability-policy) section below.
:::

The canonical function-level API reference is generated from Gleam's docs metadata and published here:

**[API Reference](/reference/api/)**

beryl is not on Hex yet, so there is no `hexdocs.pm` listing.

This page provides a module map, broadcast cheatsheet, Phoenix wire protocol reference, and client compatibility notes.

---

## Module map

| Module | What it does | When to use it |
|---|---|---|
| `beryl` | Top-level API: register channels, broadcast, `send_info` | Entry point for all applications |
| `beryl/supervisor` | Supervised startup: builds beryl's child specification and resolves stable subsystem handles | Starting beryl — this is the only entry point |
| `beryl/channel` | Channel builder, callback types, `HandleResult` | Defining channel behaviour |
| `beryl/socket` | Socket abstraction, assigns helpers | Inside channel callbacks |
| `beryl/topic` | Topic parsing, wildcard matching, segment extraction | Dynamic routing, multi-tenant patterns |
| `beryl/pubsub` | Distributed PubSub backed by Erlang `pg`, generic over payload type | Multi-node fan-out, cluster broadcasts |
| `beryl/presence` | OTP actor wrapping the presence CRDT, plus opaque `Diff` accessors | Tracking who is online |
| `beryl/group` | Named sets of topics for bulk broadcast | Rooms with multiple sub-topics |
| `beryl/bridge` | Forwards an external OTP actor's stream to a socket channel | Pushing a domain actor's updates to clients |
| `beryl/error` | Opaque `StartFailure` type returned by subsystem start functions | Handling startup errors |
| `beryl/wire` | Phoenix-compatible codec and JSON helpers | Phoenix clients, custom transports, protocol debugging |
| `beryl/wire/codec` | Pluggable codec contract for text and binary frames | Custom wire formats |
| `beryl/transport` | Transport SPI: socket lifecycle, inbound routing, edge rate limiting | Writing a custom WebSocket transport |
| `beryl/stats` | Point-in-time local coordinator snapshots and typed availability/timeout errors | Operational polling and application metrics |
| `beryl_mist` | Mist WebSocket upgrade and dispatch (separate `beryl_mist` package) | Wiring beryl to a Mist server |
| `beryl_ewe` | Ewe WebSocket upgrade and dispatch (separate `beryl_ewe` package); mirrors the `beryl_mist` API | Wiring beryl to an Ewe server |

For the stable `:telemetry` event taxonomy, snapshot semantics, and
application-owned Prometheus/Grafana export pattern, see the
[Observability guide](/guides/observability/).

---

## Broadcast / push / send cheatsheet

| Goal | API | Notes |
|---|---|---|
| Reply to an incoming message | `channel.Reply(event, payload, socket)` from `handle_in` | Sends `phx_reply` with `"status": "ok"`; the `event` arg is ignored on the wire — reply is keyed by ref |
| Fail an incoming message | `channel.ReplyError(payload, socket)` from `handle_in` | Sends `phx_reply` with `"status": "error"`, firing the client's `receive("error", ...)` hook. `Reply` cannot do this — it is always `"ok"` |
| Push to the current socket only | `channel.Push(event, payload, socket)` from `handle_in` or `handle_info` | Server-originated push on this socket's topic |
| No response | `channel.NoReply(socket)` | Use when the callback has no output |
| Broadcast to all sockets on a topic | `beryl.broadcast(channels, topic, event, payload)` | All subscribers including the sender |
| Broadcast, excluding sender | `beryl.broadcast_from(channels, socket.id(socket), topic, event, payload)` | Second arg is `except_socket_id: String`; use `socket.id/1` to extract it when you have a `Socket` value. Skips the originating socket; works across PubSub nodes |
| Send an OTP message to a joined channel context | `beryl.send_info(channels, socket_id, topic_name, message)` | Delivers the typed message to `handle_info`; the callback receives the concrete `info` value — no `Dynamic` decode and no unsafe cast required |
| Broadcast presence diff | `beryl.broadcast_presence_diff(channels, topic, diff)` | Encodes Phoenix-shaped `joins`/`leaves`; only named topic entries are included |

---

## Phoenix wire protocol reference

beryl speaks the same JSON array wire format as Phoenix channels. All frames are JSON arrays with five elements:

```
[join_ref, ref, topic, event, payload]
```

| Field | Type | Description |
|---|---|---|
| `join_ref` | string or `null` | Reference from the original `phx_join` frame; `null` for server-initiated pushes |
| `ref` | string or `null` | Per-message reference echoed in the reply; `null` for pushes |
| `topic` | string | The channel topic, e.g. `"room:lobby"` |
| `event` | string | Event name |
| `payload` | object | Arbitrary JSON object |

### System events

| Event | Direction | Meaning |
|---|---|---|
| `phx_join` | client → server | Request to join a topic |
| `phx_leave` | client → server | Unsubscribe from a topic |
| `phx_reply` | server → client | Reply to a client message, `"status"` of `"ok"` or `"error"`. Rejected joins arrive this way, not as `phx_error` |
| `phx_error` | server → client | The channel terminated abnormally |
| `phx_close` | server → client | Channel closed by server |
| `heartbeat` | client → server | Keep-alive ping (topic `"phoenix"`) |

### Reply shape (`phx_reply`)

Sent in response to any client message. The `event` arg passed to `channel.Reply` is not reflected on the wire — the frame always uses `phx_reply` and the original `ref`. `status` is what distinguishes success from failure, and it is set by which result you return, never by the payload:

```json
// channel.Reply(event, payload, socket)
[join_ref, original_ref, "topic:name", "phx_reply", {"status": "ok", "response": <your_payload>}]

// channel.ReplyError(payload, socket)
[join_ref, original_ref, "topic:name", "phx_reply", {"status": "error", "response": <your_payload>}]
```

A join reply uses the `join_ref` as both `join_ref` and `ref`:

```json
["1", "1", "room:lobby", "phx_reply", {"status": "ok", "response": {}}]
```

### Heartbeat shape

The client sends heartbeats on the `"phoenix"` topic; beryl replies immediately:

```json
// client →
[null, "ref", "phoenix", "heartbeat", {}]

// server →
[null, "ref", "phoenix", "phx_reply", {"status": "ok", "response": {}}]
```

### Presence diff shape

Follows the Phoenix presence diff format. Both `joins` and `leaves` are objects keyed by presence key (typically the user ID). Each value has a `metas` array:

```json
{
  "joins": {
    "user:42": { "metas": [{ "phx_ref": "abc123", "online_at": 1234567890 }] }
  },
  "leaves": {
    "user:99": { "metas": [{ "phx_ref": "xyz789" }] }
  }
}
```

`broadcast_presence_diff` encodes only named topic entries (entries with an explicit key). Anonymous entries are excluded.

---

## Client compatibility

When started with `wire.phoenix_codec()`, beryl uses the standard Phoenix wire format, so any Phoenix-compatible WebSocket client works out of the box:

| Client | Notes |
|---|---|
| [`phoenix.js`](https://hexdocs.pm/phoenix/js/) | Official JS client; full support |
| [`phx`](https://github.com/nmbr73/phx) | Gleam client; designed for beryl |
| Phoenix Swift / Kotlin clients | Community Phoenix clients; wire-compatible |
| Plain WebSocket | Use the JSON array format directly; no reconnect logic |

The WebSocket upgrade path is caller-provided — there is no default. Pass the path when constructing your transport config with `mist_transport.default_config(path)`. The Phoenix JS client appends `/websocket` to the socket endpoint, so if you configure the client with `"/socket"`, mount your handler at `"/socket/websocket"`. See the [WebSocket Transport guide](/guides/websocket/) for details.

---

## Pre-1.0 stability policy

beryl follows [Semantic Versioning](https://semver.org/) but is **not yet 1.0**. Until the 1.0 release:

- **Minor version bumps** (`0.x → 0.x+1`) may include breaking changes to the public API.
- **Patch version bumps** (`0.x.y → 0.x.y+1`) fix bugs without intentional breakage.
- Public API is defined as the exports of the modules listed in the module map above.
- Coordinator, rate-limit, and internal helper modules are intentionally hidden from downstream packages. Transports integrate through the public `beryl/transport` SPI; `beryl_mist` and `beryl_ewe` are the supported WebSocket transports.

Check [GitHub releases](https://github.com/tylerbutler/beryl/releases) before upgrading to a new minor version.
