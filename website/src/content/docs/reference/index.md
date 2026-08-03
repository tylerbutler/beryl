---
title: Reference
description: Module map, wire protocol, broadcast cheatsheet, and client compatibility for beryl.
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable and may change in minor releases. See the [Stability policy](#pre-10-stability-policy) section below.
:::

The canonical function-level API reference is the generated Gleam documentation hosted on HexDocs — [beryl](https://hexdocs.pm/beryl/) and [beryl_channels](https://hexdocs.pm/beryl_channels/) — mirrored on this site under [Generated API](/reference/api/).

This page provides a module map, action/effect cheatsheets, the Phoenix wire protocol reference, and client compatibility notes.

---

## Module map

beryl ships two programming layers over one runtime; see [Choose an API](/choosing-an-api/).

### Channel layer — package `beryl_channels`

| Module | What it does | When to use it |
|---|---|---|
| `beryl_channels` | Channel-system lifecycle: `start`, `child_spec`, `validate_handlers`, and their error types | Entry point for a handler-table socket system |
| `beryl_channels/channel` | The composition surface: `Handler`, `JoinInfo`, `Sender`, `Callbacks`, `Actions`, join results, and `Next` results | Writing individual channels |

### Core — package `beryl`

| Module | What it does | When to use it |
|---|---|---|
| `beryl` | Top-level app-side dispatch lifecycle, config builders, and broadcast helpers | Entry point for starting/stopping a Beryl socket system, on either layer |
| `beryl/socket` | `Input`, `Next`, `Effect`, `Ref`, `ConnectInfo`, `ConnectSeed`, `StopReason`, and `Sender` types | Writing your app's `init` and `update` functions |
| `beryl/bridge` | Forward an external OTP actor's message stream into `socket.Info(...)` | Bridging domain actors to one socket without hand-rolled forwarders |
| `beryl/topic` | Topic parsing, wildcard matching, segment extraction | Dynamic routing, multi-tenant patterns |
| `beryl/pubsub` | Distributed PubSub backed by Erlang `pg`, with typed subscribers and topic joins/leaves | Multi-node fan-out, cluster broadcasts, custom background consumers |
| `beryl/presence` | OTP actor wrapping the presence CRDT, plus opaque `Diff` accessors | Tracking who is online |
| `beryl/group` | Named sets of topics for bulk broadcast | Rooms with multiple sub-topics |
| `beryl/wire` | Phoenix-compatible codec and Dynamic→JSON helpers | Phoenix clients, payload relays, protocol debugging |
| `beryl/wire/codec` | Pluggable codec contract for text and binary frames | Custom wire formats |
| `beryl/transport` | Transport SPI: socket lifecycle, inbound routing, and edge rate limiting | Writing a custom transport package |
| `beryl_mist` | Mist WebSocket upgrade and request handler integration (separate `beryl_mist` package) | Wiring beryl to a Mist HTTP server |
| `beryl_ewe` | Ewe WebSocket transport (separate `beryl_ewe` package) | Wiring beryl to an Ewe HTTP server |

---

## Broadcast / push / send cheatsheet

Both columns produce the same frames. Channel actions are always scoped to the channel's own topic, so they take no topic argument.

| Goal | Channel layer (`channel`) | Raw dispatch (`socket`) |
|---|---|---|
| Accept a join | `channel.accept(joined)` / `channel.accept_with(joined, reply)` | `socket.AcceptJoin(ref, reply)` from `socket.Join` |
| Reject a join | `channel.reject(reason)` | `socket.RejectJoin(ref, reason)` from `socket.Join` |
| Run work as part of the accepted join | `channel.with_actions(result, actions)` | order the effects after `AcceptJoin` in the same list |
| Reply to an incoming message | `channel.reply_ok(ref, payload)` / `channel.reply_error(ref, payload)` | `socket.ReplyOk(ref, payload)` / `socket.ReplyError(ref, payload)` |
| Push to the current socket only | `channel.push(event, payload)` | `socket.Push(topic, event, payload)` |
| No response | `channel.continue(state)` | `socket.Next(model, [])` |
| Broadcast to all sockets on a topic | `channel.broadcast(event, payload)`, or `beryl.broadcast(sockets, topic, event, payload)` from outside | `socket.Broadcast(topic, event, payload)`, or `beryl.broadcast(..)` from outside |
| Broadcast, excluding sender | `channel.broadcast_from(event, payload)` | `socket.BroadcastFrom(topic, event, payload)`, or `beryl.broadcast_from(sockets, socket_id, ..)` from outside |
| Track / untrack presence | `channel.presence_track(key, meta)` / `channel.presence_untrack(key)` | `socket.PresenceTrack(topic, key, meta)` / `socket.PresenceUntrack(topic, key)` |
| Presence snapshot | `channel.push_presence(event, encode)` / `channel.broadcast_presence(event, encode)` | `socket.PushPresence(topic, event, encode)` / `socket.BroadcastPresence(topic, event, encode)` |
| Send a typed server-side message | `channel.notify(sender, message)` with `JoinInfo.self` — arrives as `on_info` | `socket.notify(sender, message)` with `ConnectInfo.self` — arrives as `socket.Info(message)` |
| End one topic | `channel.close()` / `channel.close_with(actions)` | `socket.KickTopic(topic)` |
| End the whole socket | `channel.stop_socket(reason)` | `socket.Stop(reason)` |
| Clean up when a topic ends | `channel.on_terminate` (returns actions) | the `socket.Closed(topic, reason)` branch |
| Broadcast presence diff from outside | `beryl.broadcast_presence_diff(sockets, topic, diff)` | same |

Replies are keyed by ref, not by event name. Effects and actions are applied strictly in list order, and list order is wire order.

Two ordering rules worth memorizing:

- A join's actions run in the same turn as, and strictly after, the acknowledgment — so a push can never overtake its own join reply.
- Termination actions run after the topic is unsubscribed, so `push` and `push_presence` are dropped there while broadcasts and presence changes still apply.

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

Sent in response to any client message. `socket.ReplyOk` / `socket.ReplyError` — and the `channel.reply_ok` / `channel.reply_error` actions that lower onto them — always serialize as `phx_reply` keyed by the original ref.

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

The WebSocket upgrade path is caller-provided — there is no default. Pass the path when constructing your transport config with `beryl/transport/server.default_config(path)`. The Phoenix JS client appends `/websocket` to the socket endpoint, so if you configure the client with `"/socket"`, mount your handler at `"/socket/websocket"`. See the [WebSocket Transport guide](/guides/websocket) for details.

---

## Pre-1.0 stability policy

beryl follows [Semantic Versioning](https://semver.org/) but is **not yet 1.0**. Until the 1.0 release:

- **Minor version bumps** (`0.x → 0.x+1`) may include breaking changes to the public API.
- **Patch version bumps** (`0.x.y → 0.x.y+1`) fix bugs without intentional breakage.
- Public API is defined as the exports of the modules listed in the module map above. `beryl_channels` versions independently of `beryl` and follows the same policy.
- `beryl_channels/internal/*` is package-internal: Gleam hides it from other packages and from the generated docs.
- The internal modules `beryl/connection_limit`, `beryl/internal`, `beryl/log`, `beryl/rate_limit`, and `beryl/runtime` are intentionally hidden from downstream packages. Transports integrate through the public `beryl/transport` SPI; `beryl_mist` is the supported Mist WebSocket transport.

Check [GitHub releases](https://github.com/tylerbutler/beryl/releases) before upgrading to a new minor version.
