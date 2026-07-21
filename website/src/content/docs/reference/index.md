---
title: Reference
description: Module map, wire protocol, broadcast cheatsheet, and client compatibility for beryl.
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable and may change in minor releases. See the [Stability policy](#pre-10-stability-policy) section below.
:::

The canonical function-level API reference is the generated Gleam documentation hosted on HexDocs:

**[https://hexdocs.pm/beryl/](https://hexdocs.pm/beryl/)**

This page provides a module map, broadcast cheatsheet, Phoenix wire protocol reference, and client compatibility notes.

---

## Module map

| Module | What it does | When to use it |
|---|---|---|
| `beryl` | Top-level API: start the registry, register channels, broadcast | Entry point for all applications |
| `beryl/channel` | Channel builder, callback types, `HandleResult` | Defining channel behaviour |
| `beryl/socket` | Socket abstraction, assigns helpers | Inside channel callbacks |
| `beryl/topic` | Topic parsing, wildcard matching, segment extraction | Dynamic routing, multi-tenant patterns |
| `beryl/pubsub` | Distributed PubSub backed by Erlang `pg` | Multi-node fan-out, cluster broadcasts |
| `beryl/presence` | OTP actor wrapping the presence CRDT, plus opaque `Diff` accessors | Tracking who is online |
| `beryl/group` | Named sets of topics for bulk broadcast | Rooms with multiple sub-topics |
| `beryl/wire` | Phoenix-compatible codec and JSON helpers | Phoenix clients, custom transports, protocol debugging |
| `beryl/wire/codec` | Pluggable codec contract for text and binary frames | Custom wire formats |
| `beryl/transport` | Transport SPI: socket lifecycle, inbound routing, edge rate limiting | Writing a custom WebSocket transport |
| `beryl_mist` | Mist WebSocket upgrade and dispatch (separate `beryl_mist` package) | Wiring beryl to an HTTP server |

---

## Broadcast / push / send cheatsheet

| Goal | API | Notes |
|---|---|---|
| Reply to an incoming message | `channel.Reply(event, payload, socket)` from `handle_in` | Sends `phx_reply`; the `event` arg is ignored on the wire — reply is keyed by ref |
| Push to the current socket only | `channel.Push(event, payload, socket)` from `handle_in` or `handle_info` | Server-originated push on this socket's topic |
| No response | `channel.NoReply(socket)` | Use when the handler has no output |
| Broadcast to all sockets on a topic | `beryl.broadcast(registry, topic, event, payload)` | All subscribers including the sender |
| Broadcast, excluding sender | `beryl.broadcast_from(channels, socket.id(socket), topic, event, payload)` | Second arg is `except_socket_id: String`; use `socket.id/1` to extract it when you have a `Socket` value. Skips the originating socket; works across PubSub nodes |
| Send an OTP message to a joined channel context | `beryl.send_info(channels, socket_id, topic_name, message)` | Delivers the typed message to `handle_info`; the callback receives the concrete `info` value — no `Dynamic` decode and no unsafe cast required |
| Broadcast presence diff | `beryl.broadcast_presence_diff(registry, topic, diff)` | Encodes Phoenix-shaped `joins`/`leaves`; only named topic entries are included |

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
| `phx_reply` | server → client | Reply to a client message |
| `phx_error` | server → client | Join rejected or channel error |
| `phx_close` | server → client | Channel closed by server |
| `heartbeat` | client → server | Keep-alive ping (topic `"phoenix"`) |

### Reply shape (`phx_reply`)

Sent in response to any client message. The `event` arg passed to `channel.Reply` is not reflected on the wire — the frame always uses `phx_reply` and the original `ref`.

```json
[join_ref, original_ref, "topic:name", "phx_reply", {"status": "ok", "response": <your_payload>}]
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

The WebSocket upgrade path is caller-provided — there is no default. Pass the path when constructing your transport config with `mist_transport.default_config(path)`. The Phoenix JS client appends `/websocket` to the socket endpoint, so if you configure the client with `"/socket"`, mount your handler at `"/socket/websocket"`. See the [WebSocket Transport guide](/guides/websocket) for details.

---

## Pre-1.0 stability policy

beryl follows [Semantic Versioning](https://semver.org/) but is **not yet 1.0**. Until the 1.0 release:

- **Minor version bumps** (`0.x → 0.x+1`) may include breaking changes to the public API.
- **Patch version bumps** (`0.x.y → 0.x.y+1`) fix bugs without intentional breakage.
- Public API is defined as the exports of the modules listed in the module map above.
- Coordinator, rate-limit, and internal helper modules are intentionally hidden from downstream packages. Transports integrate through the public `beryl/transport` SPI; `beryl_mist` is the supported WebSocket transport.

Check [GitHub releases](https://github.com/tylerbutler/beryl/releases) before upgrading to a new minor version.
