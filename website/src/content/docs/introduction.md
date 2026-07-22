---
title: What is beryl?
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable, features may be removed in minor releases, and quality should not be considered production-ready. We welcome usage and feedback in the meantime!
:::

beryl is a **type-safe real-time channels and presence library** for Gleam,
targeting the Erlang (BEAM) runtime. It provides the building blocks for adding
real-time features to your Gleam web applications.

## Why beryl?

Building real-time features — like chat rooms, live cursors, collaborative
editing, or presence indicators — requires coordinating state across many
connected clients. beryl gives you:

- **App-side dispatch** — Topic-based routing in your app's `update` function, with pattern matching such as `"room:*"`
- **Presence** — Distributed tracking of connected users backed by a conflict-free CRDT
- **PubSub** — Distributed publish/subscribe built on Erlang's `pg` process groups
- **Groups** — Named collections of topics for multi-topic broadcasting
- **WebSocket transport** — Mist integration with JSON wire protocol (Phoenix-compatible)

## Design principles

### Type safety first

Your socket app owns one `Model` type and one `update` function. The Gleam
compiler keeps every branch honest:

```gleam
import beryl/event
import gleam/json

pub type Model {
  Model(user_id: String, room_id: String)
}

fn update(model: Model, ev: event.Event(Nil)) -> event.Next(Model, Nil) {
  case ev {
    event.Join("room:" <> room_id, _payload, ref) ->
      event.Next(Model(..model, room_id: room_id), [event.AcceptJoin(ref, None)])

    event.Message(topic, "typing", _payload, _ref) ->
      event.Next(
        model,
        [event.BroadcastFrom(
          topic,
          "typing",
          json.object([#("user_id", json.string(model.user_id))]),
        )],
      )

    _ -> event.Next(model, [])
  }
}
```

### Built on OTP

The runtime behind each `beryl.Sockets` handle is an OTP actor. Presence
tracking is a separate OTP actor wrapping a CRDT, and PubSub uses Erlang's `pg`
directly.

### CRDT-backed presence

Presence state uses an **add-wins observed-remove set** (AWORSet) with causal
context — a conflict-free replicated data type that resolves concurrent joins
and leaves automatically, even across distributed Erlang nodes.

### Focused dependencies

The core library depends on `gleam_stdlib`, `gleam_erlang`, `gleam_otp`,
`gleam_json`, `gleam_crypto`, `lattice_presence`, and `palabres` — all standard
BEAM ecosystem packages. A WebSocket transport such as `beryl_mist` adds `mist`
and `gleam_http`, but the core library pulls in neither. No external message
brokers or databases required.

### Phoenix wire protocol compatibility

beryl uses the same JSON array wire format as Phoenix channels
(`[join_ref, ref, topic, event, payload]`), making it compatible with existing
Phoenix client libraries.

## Next steps

- [Quick Start](/quick-start/) — get a working server in minutes
- [Dispatch guide](/guides/dispatch/) — route topics, messages, and close events in one app
- [Supervision guide](/guides/supervision/) — production startup with OTP supervision
- [Error Handling guide](/guides/error-handling/) — rejected joins, rate limits, and more
- [Troubleshooting](/troubleshooting/) — symptom-first diagnostics
