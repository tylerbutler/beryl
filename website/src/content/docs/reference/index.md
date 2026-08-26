---
title: Reference
description: Find beryl modules, message-sending APIs, Phoenix frame formats, and compatible clients.
---

:::note[Pre-1.0]
beryl is not yet version 1.0. Minor releases can change the API. The library is
not ready for production. See the
[stability policy](#versioning-before-10).
:::

The site generates the function-level API reference from Gleam docs metadata.
Install beryl packages from GitHub. They are not on Hex:

**[beryl](/reference/api/beryl/)** ·
**[beryl/channel](/reference/api/beryl-channel/)**

Use this page to find a module, choose how to send a message, inspect Phoenix
frames, or select a compatible client.

---

## Module map

| Module | What it does | When to use it |
|---|---|---|
| `beryl` | Start and stop raw-dispatch socket systems, configure them, and broadcast events | Building or stopping a beryl socket system |
| `beryl/channel` | Validate handlers, start them under a supervisor, and define typed callbacks, senders, and actions | Recommended programming model for apps with several topic features |
| `beryl/socket` | `Input`, `Next`, `Effect`, `ConnectInfo`, and `Sender` types | Writing your app's `init` and `update` functions |
| `beryl/bridge` | Forward an external OTP actor's message stream into `socket.Info(...)` | Bridging domain actors to one socket without hand-rolled forwarders |
| `beryl/topic` | Topic parsing, wildcard matching, segment extraction | Dynamic routing, multi-tenant patterns |
| `beryl/pubsub` | Distributed PubSub backed by Erlang `pg`, with typed subscribers and topic joins/leaves | Broadcasts across nodes and custom background subscribers |
| `beryl/presence` | OTP actor wrapping the presence CRDT, plus opaque `Diff` accessors | Tracking who is online |
| `beryl/presence/wire` | Phoenix-compatible presence state and diff encoders | Sending presence payloads to Phoenix clients |
| `beryl/group` | Named sets of topics for bulk broadcast | Rooms with multiple sub-topics |
| `beryl/error` | Shared opaque error helpers | Handling Beryl-owned startup errors |
| `beryl/stats` | Local runtime snapshots | Reporting connected sockets, memberships, and active topics |
| `beryl/wire` | Phoenix-compatible codec and Dynamic→JSON helpers | Phoenix clients, payload relays, protocol debugging |
| `beryl/wire/codec` | Pluggable codec contract for text and binary frames | Custom wire formats |
| `beryl/transport` | Public interface for socket setup, incoming messages, and rate limiting | Writing a custom transport package |
| `beryl/transport/origin` | Origin and Phoenix version checks | Validating WebSocket upgrades |
| `beryl/transport/server` | Shared connection and frame handling for any WebSocket server | Implementing a WebSocket transport |
| `beryl_mist` | Mist WebSocket upgrade and request handler integration (separate `beryl_mist` package) | Wiring beryl to a Mist HTTP server |
| `beryl_ewe` | Ewe WebSocket transport integration (separate `beryl_ewe` package) | Wiring beryl to an Ewe HTTP server |

---

## Choose how to send a message

| Goal | API | Notes |
|---|---|---|
| Accept a join | `socket.AcceptJoin(ref, reply)` from `socket.Join` | Sends the join `phx_reply` and subscribes the socket to the topic |
| Reject a join | `socket.RejectJoin(ref, reason)` from `socket.Join` | Fails the join immediately; unanswered joins are rejected automatically too |
| Reply to an incoming message | `socket.ReplyOk(ref, payload)` or `socket.ReplyError(ref, payload)` from `socket.Message(..., Some(ref))` | Sends `phx_reply`; replies are keyed by ref, not by event name |
| Push to the current socket only | `socket.Push(topic, event, payload)` | Server-originated push on a topic this socket already joined |
| No response | `socket.Next(model, [])` | Continue without outgoing frames or side effects |
| Broadcast to all sockets on a topic | `socket.Broadcast(topic, event, payload)` inside `update`, or `beryl.broadcast(sockets, topic, event, payload)` outside it | All subscribers, including the sender |
| Broadcast, excluding sender | `socket.BroadcastFrom(topic, event, payload)` inside `update`, or `beryl.broadcast_from(sockets, socket_id, topic, event, payload)` outside it | Excludes one socket ID; preserved across PubSub nodes |
| Send a typed server-side message to one socket | `socket.notify(sender, message)` | Store `ConnectInfo.self` from `init`; delivered later as `socket.Info(message)` |
| Broadcast presence diff | `beryl.broadcast_presence_diff(sockets, topic, diff)` | Manual Phoenix-shaped `presence_diff`; ordinary socket/channel presence effects are applied asynchronously by the runtime |

The channel layer provides topic-scoped versions through ordered
`channel.Action(Active)` lists. These actions include `push`, `broadcast`,
`broadcast_from`, `reply_ok`, `reply_error`, and the presence actions. They use
the same core effects.

---

## Phoenix frame format

With `wire.phoenix_codec()`, beryl uses the Phoenix Channels JSON array format.
Each frame has five elements:

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

### Reply frame (`phx_reply`)

The server sends this frame in response to a client message. `socket.ReplyOk`
and `socket.ReplyError` use `phx_reply` with the original ref.

```json
[join_ref, original_ref, "topic:name", "phx_reply", {"status": "ok", "response": <your_payload>}]
```

A join reply uses the `join_ref` as both `join_ref` and `ref`:

```json
["1", "1", "room:lobby", "phx_reply", {"status": "ok", "response": {}}]
```

### Heartbeat frames

The client sends heartbeats on the `"phoenix"` topic; beryl replies immediately:

```json
// client →
[null, "ref", "phoenix", "heartbeat", {}]

// server →
[null, "ref", "phoenix", "phx_reply", {"status": "ok", "response": {}}]
```

### Presence update

The payload uses the Phoenix presence diff format. The `joins` and `leaves`
objects use the presence key, usually the user ID. Each value has a `metas`
array:

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

With `wire.phoenix_codec()`, beryl uses the standard Phoenix wire format. You
can use any compatible WebSocket client:

| Client | Notes |
|---|---|
| [`phoenix.js`](https://hexdocs.pm/phoenix/js/) | Official JS client; full support |
| [`phx`](https://github.com/nmbr73/phx) | Gleam client; designed for beryl |
| Phoenix Swift / Kotlin clients | Community Phoenix clients; wire-compatible |
| Plain WebSocket | Use the JSON array format directly; no reconnect logic |

You must set the WebSocket upgrade path. Pass the path to
`beryl/transport/server.default_config(path)`. The Phoenix JS client adds
`/websocket` to the socket endpoint. If the client uses `"/socket"`, mount the
handler at `"/socket/websocket"`. See the
[WebSocket Transport guide](/guides/websocket).

---

## Versioning before 1.0

beryl follows [Semantic Versioning](https://semver.org/) but is **not yet 1.0**. Until the 1.0 release:

- **Minor version bumps** (`0.x → 0.x+1`) may include breaking changes to the public API.
- **Patch version bumps** (`0.x.y → 0.x.y+1`) fix bugs without intentional breakage.
- Public API is defined as the exports of the modules listed in the module map
  above, including `beryl/channel`.
- The internal modules `beryl/app_supervisor`, `beryl/connection_limit`,
  `beryl/internal`, `beryl/log`, `beryl/rate_limit`, `beryl/runtime`, and
  `beryl/telemetry` are intentionally hidden from downstream packages.
  Transports integrate through the public `beryl/transport` SPI.

Check [GitHub releases](https://github.com/tylerbutler/beryl/releases) before upgrading to a new minor version.
