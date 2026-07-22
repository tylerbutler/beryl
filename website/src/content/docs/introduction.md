---
title: What is beryl?
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable, features may be removed in minor releases, and quality should not be considered production-ready. We welcome usage and feedback in the meantime!
:::

beryl is a **type-safe real-time channels and presence library** for Gleam, targeting the Erlang (BEAM) runtime. It provides the building blocks for adding real-time features to your Gleam web applications.

## Why beryl?

Building real-time features — like chat rooms, live cursors, collaborative editing, or presence indicators — requires coordinating state across many connected clients. beryl gives you:

- **Channels** — One typed `init`/`update` pair per socket handles every topic; your app routes topics itself with ordinary pattern matching (`"room:" <> _`)
- **Presence** — Distributed tracking of connected users backed by a conflict-free CRDT
- **PubSub** — Distributed publish/subscribe built on Erlang's `pg` process groups
- **Groups** — Named collections of topics for multi-topic broadcasting
- **WebSocket transport** — Mist integration with JSON wire protocol (Phoenix-compatible)

## Design principles

### Type safety first

Your app supplies a model type and an update function, and the Gleam compiler
checks every event end to end — there are no unchecked casts and no `Dynamic`
round-trips anywhere in the dispatch path:

```gleam
pub type Model {
  Model(user_id: String, room_id: String)
}

// The compiler ensures update receives your Model and returns the next one
fn update(model: Model, ev: event.Event(Msg)) -> event.Next(Model, Msg) {
  // model.user_id and model.room_id are guaranteed to exist
  event.Next(model, [])
}
```

Server-side messages are typed too: processes reach a socket through a
`Sender(msg)`, and the message arrives in `update` as `Info(msg)` for
exhaustive pattern matching.

### Built on OTP

beryl leverages OTP actors and Erlang's `pg` process groups rather than reinventing distributed primitives. The runtime is a supervised OTP actor, presence tracking is an OTP actor wrapping a CRDT, and PubSub uses `pg` directly.

### CRDT-backed presence

Presence state uses an **add-wins observed-remove set** (AWORSet) with causal context — a conflict-free replicated data type that resolves concurrent joins and leaves automatically, even across distributed Erlang nodes.

### Focused dependencies

The core library depends on `gleam_stdlib`, `gleam_erlang`, `gleam_otp`, `gleam_json`, `gleam_crypto`, `lattice_presence`, and `palabres` — all standard BEAM ecosystem packages. A WebSocket transport such as `beryl_mist` adds `mist` and `gleam_http`, but the core library pulls in neither. No external message brokers or databases required.

### Phoenix wire protocol compatibility

beryl uses the same JSON array wire format as Phoenix channels (`[join_ref, ref, topic, event, payload]`), making it compatible with existing Phoenix client libraries.

## Next steps

- [Quick Start](/quick-start/) — get a working server in minutes
- [Channels guide](/guides/channels) — events, effects, and broadcasting
- [Supervision guide](/guides/supervision) — the built-in runtime supervision
- [Error Handling guide](/guides/error-handling) — rejected joins, rate limits, and more
- [Troubleshooting](/troubleshooting) — symptom-first diagnostics
