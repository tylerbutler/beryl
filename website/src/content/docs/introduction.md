---
title: What is beryl?
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable, features may be removed in minor releases, and quality should not be considered production-ready. We welcome usage and feedback in the meantime!
:::

beryl is a **type-safe real-time channels and presence library** for Gleam, targeting the Erlang (BEAM) runtime. It provides the building blocks for adding real-time features to your Gleam web applications.

## Why beryl?

Building real-time features — like chat rooms, live cursors, collaborative editing, or presence indicators — requires coordinating state across many connected clients. beryl gives you:

- **Channels** — Topic-based message handlers with typed callbacks and pattern matching (`"room:*"`)
- **Presence** — Distributed tracking of connected users backed by a conflict-free CRDT
- **PubSub** — Distributed publish/subscribe built on Erlang's `pg` process groups
- **Groups** — Named collections of topics for multi-topic broadcasting
- **WebSocket transport** — Wisp integration with JSON wire protocol (Phoenix-compatible)

## Design principles

### Type safety first

All channel callbacks are fully typed. Define your own assigns type per channel, and the Gleam compiler catches mismatches at build time:

```gleam
pub type RoomAssigns {
  RoomAssigns(user_id: String, room_id: String)
}

// The compiler ensures handle_in receives Socket(RoomAssigns)
fn handle_in(event: String, payload: Json, socket: Socket(RoomAssigns)) -> HandleResult(RoomAssigns) {
  let assigns = socket.get_assigns(socket)
  // assigns.user_id and assigns.room_id are guaranteed to exist
  channel.NoReply(socket)
}
```

### Built on OTP

beryl leverages OTP actors and Erlang's `pg` process groups rather than reinventing distributed primitives. The coordinator is an OTP actor, presence tracking is an OTP actor wrapping a CRDT, and PubSub uses `pg` directly.

### CRDT-backed presence

Presence state uses an **add-wins observed-remove set** (AWORSet) with causal context — a conflict-free replicated data type that resolves concurrent joins and leaves automatically, even across distributed Erlang nodes.

### Minimal dependencies

The core library depends only on `gleam_stdlib`, `gleam_erlang`, `gleam_otp`, `gleam_json`, and `gleam_crypto`. No external message brokers or databases required.

### Phoenix wire protocol compatibility

beryl uses the same JSON array wire format as Phoenix channels (`[join_ref, ref, topic, event, payload]`), making it compatible with existing Phoenix client libraries.
