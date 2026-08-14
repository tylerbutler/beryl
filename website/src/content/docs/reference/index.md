---
title: Reference
description: Module map, wire protocol, broadcast cheatsheet, and client compatibility for beryl.
---

:::note[Pre-1.0]
beryl is pre-1.0: the API can change between minor releases and it isn't production-hardened yet. See the [stability policy](#pre-10-stability-policy) below.
:::

The function-level API reference lives in the [Generated API](/reference/api/)
section of this site, built from the source on `main`. (beryl isn't published
to Hex yet, so there is no HexDocs page — the generated docs here are the
reference until then.)

This page provides a module map, broadcast cheatsheet, Phoenix wire protocol reference, and client compatibility notes.

---

## Module map

| Module | What it does | When to use it |
|---|---|---|
| `beryl` | Top-level app-side dispatch lifecycle, config builders, and broadcast helpers | Entry point for starting/stopping a Beryl socket system |
| `beryl/event` | `Event`, `Next`, `Effect`, `ConnectInfo`, and `Sender` types | Writing your app's `init` and `update` functions |
| `beryl/bridge` | Forward an external OTP actor's message stream into `event.Info(...)` | Bridging domain actors to one socket without hand-rolled forwarders |
| `beryl/topic` | Topic parsing, wildcard matching, segment extraction | Dynamic routing, multi-tenant patterns |
| `beryl/pubsub` | Distributed PubSub backed by Erlang `pg`, with typed subscribers and topic joins/leaves | Multi-node fan-out, cluster broadcasts, custom background consumers |
| `beryl/presence` | OTP actor wrapping the presence CRDT, plus opaque `Diff` accessors | Tracking who is online |
| `beryl/group` | Named sets of topics for bulk broadcast | Rooms with multiple sub-topics |
| `beryl/wire` | Phoenix-compatible codec and Dynamic→JSON helpers | Phoenix clients, payload relays, protocol debugging |
| `beryl/wire/codec` | Pluggable codec contract for text and binary frames | Custom wire formats |
| `beryl/transport` | Transport SPI: socket lifecycle, inbound routing, and edge rate limiting | Writing a custom transport package |
| `beryl_mist` | Mist WebSocket upgrade and request handler integration (separate `beryl_mist` package) | Wiring beryl to a Mist HTTP server |

---

## Broadcast / push / send cheatsheet

| Goal | API | Notes |
|---|---|---|
| Accept a join | `event.AcceptJoin(ref, reply)` from `event.Join` | Sends the join `phx_reply` and subscribes the socket to the topic |
| Reject a join | `event.RejectJoin(ref, reason)` from `event.Join` | Fails the join immediately; unanswered joins are rejected automatically too |
| Reply to an incoming message | `event.ReplyOk(ref, payload)` or `event.ReplyError(ref, payload)` from `event.Message(..., Some(ref))` | Sends `phx_reply`; replies are keyed by ref, not by event name |
| Push to the current socket only | `event.Push(topic, event, payload)` | Server-originated push on a topic this socket already joined |
| No response | `event.Next(model, [])` | Continue without outgoing frames or side effects |
| Broadcast to all sockets on a topic | `event.Broadcast(topic, event, payload)` inside `update`, or `beryl.broadcast(sockets, topic, event, payload)` outside it | All subscribers, including the sender |
| Broadcast, excluding sender | `event.BroadcastFrom(topic, event, payload)` inside `update`, or `beryl.broadcast_from(sockets, socket_id, topic, event, payload)` outside it | Excludes one socket ID; preserved across PubSub nodes |
| Send a typed server-side message to one socket | `event.notify(sender, message)` | Store `ConnectInfo.self` from `init`; delivered later as `event.Info(message)` |
| Broadcast presence diff | `beryl.broadcast_presence_diff(sockets, topic, diff)` | Manual Phoenix-shaped `presence_diff`; perform synchronous presence mutations in an application-owned worker |

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

Sent in response to any client message. `event.ReplyOk` and `event.ReplyError` always serialize as `phx_reply` keyed by the original ref.

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
- The internal modules `beryl/connection_limit`, `beryl/internal`, `beryl/log`, `beryl/rate_limit`, and `beryl/runtime` are intentionally hidden from downstream packages. Transports integrate through the public `beryl/transport` SPI; `beryl_mist` is the supported Mist WebSocket transport.

Check [GitHub releases](https://github.com/tylerbutler/beryl/releases) before upgrading to a new minor version.
