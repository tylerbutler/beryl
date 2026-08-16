---
title: What is beryl?
---

:::note[Pre-1.0]
beryl is pre-1.0: the API can change between minor releases and it isn't production-hardened yet. Build with it and tell us what breaks; that feedback is shaping 1.0.
:::

beryl is a **type-safe real-time channels and presence library** for Gleam,
targeting the Erlang (BEAM) runtime. It provides the building blocks for adding
real-time features to your Gleam web applications.

## Why beryl?

Building real-time features — like chat rooms, live cursors, collaborative
editing, or presence indicators — requires coordinating state across many
connected clients. beryl gives you:

- **Channels** — Register one handler per topic pattern; each channel keeps private, typed state and its own server-side message type (`beryl_channels`)
- **App-side dispatch** — Or route every socket event yourself in one typed `update` function, with pattern matching such as `"room:*"`
- **Presence** — Distributed tracking of connected users backed by a conflict-free CRDT
- **PubSub** — Distributed publish/subscribe built on Erlang's `pg` process groups
- **Groups** — Named collections of topics for multi-topic broadcasting
- **WebSocket transport** — Mist integration with JSON wire protocol (Phoenix-compatible)

## Two layers, one runtime

beryl ships one runtime and two ways to program it.

The **channel layer** (`beryl_channels`) is the recommended default. You
register a list of channel handlers — a topic pattern plus a typed `join`
callback — and the layer routes every join, message, binary frame, typed
server-side message, and close to the channel that owns the topic:

```gleam
let assert Ok(#(sockets, spec)) =
  beryl_channels.child_spec(
    beryl.config(wire.phoenix_codec()),
    handlers: [lobby.channel(), rooms.channel(), documents.channel()],
  )
```

**Raw app-side dispatch** (`beryl`) is the core underneath. You pass one
`init`/`update` pair to `beryl.child_spec` and own the router yourself. It is
the right choice for a single-topic system, or when you want complete control
over routing and effect ordering:

```gleam
let assert Ok(#(sockets, spec)) =
  beryl.child_spec(
    beryl.config(wire.phoenix_codec()),
    init: init,
    update: update,
  )
```

Both lower to the same runtime, wire codec, presence, PubSub, and abuse
controls — and both child specifications belong in your application's
supervision tree. The channel layer is built entirely on beryl's public API. See
[Choose an API](/choosing-an-api/) for the decision in one table.

## Design principles

### Type safety first

Nothing in beryl is erased to `Dynamic` and nothing is coerced. With the
channel layer, each channel picks its own private state type and its own
server-side message type, and both stay sealed inside that channel's closures —
which is how channels that agree on nothing compose in one list. With raw
dispatch, your socket app owns one `Model` type and one `update` function, and
the Gleam compiler keeps every branch honest:

```gleam
import beryl/socket
import gleam/json

pub type Model {
  Model(user_id: String, room_id: String)
}

fn update(model: Model, ev: socket.Input(Nil)) -> socket.Next(Model) {
  case ev {
    socket.Join("room:" <> room_id, _payload, ref) ->
      socket.Next(Model(..model, room_id: room_id), [socket.AcceptJoin(ref, None)])

    socket.Message(topic, "typing", _payload, _ref) ->
      socket.Next(
        model,
        [socket.BroadcastFrom(
          topic,
          "typing",
          json.object([#("user_id", json.string(model.user_id))]),
        )],
      )

    _ -> socket.Next(model, [])
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
and `gleam_http`, but the core library pulls in neither. `beryl_channels`
depends on `beryl` and the same shared Gleam libraries beryl already uses, so
it adds no new transitive dependencies of its own. No external message brokers
or databases required.

### Phoenix wire protocol compatibility

beryl uses the same JSON array wire format as Phoenix channels
(`[join_ref, ref, topic, event, payload]`), making it compatible with existing
Phoenix client libraries. If you know Phoenix Channels, the
[Coming from Phoenix](/guides/coming-from-phoenix/) guide maps channel
modules, callbacks, and assigns onto both of beryl's layers.

## Next steps

- [Choose an API](/choosing-an-api/) — channel layer or raw dispatch
- [Quick Start](/quick-start/) — get a working server in minutes
- [Channels guide](/guides/channels/) — handler tables, typed state, actions, and lifecycle
- [Dispatch guide](/guides/dispatch/) — route topics, messages, and close events in one app
- [Supervision guide](/guides/supervision/) — production startup with OTP supervision
- [Error Handling guide](/guides/error-handling/) — rejected joins, rate limits, and more
- [Troubleshooting](/troubleshooting/) — symptom-first diagnostics
