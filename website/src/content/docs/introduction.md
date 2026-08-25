---
title: What is beryl?
---

:::note[Pre-1.0]
beryl is not yet version 1.0. Minor releases can change the API. The library is
not ready for production. Try it and report problems. Your feedback will help
define version 1.0.
:::

beryl is a **type-safe real-time channels and presence library** for Gleam,
for the Erlang (BEAM) runtime. It helps you add real-time features to Gleam web
applications.

## Why beryl?

Real-time features must coordinate state across many connected clients. These
features include chat rooms, live cursors, shared editing, and presence
indicators. beryl provides:

- **Channels:** Register one handler for each topic pattern. Each channel keeps
  private, typed state and a server-side message type (`beryl/channel`).
- **App-side dispatch:** Route all socket events in one typed `update` function.
  Match topic patterns such as `"room:*"`.
- **Presence:** Track connected users across nodes with a conflict-free CRDT.
- **PubSub:** Publish and subscribe across nodes with Erlang `pg` process groups.
- **Groups:** Put topics in named groups for multi-topic broadcasts.
- **WebSocket transport:** Use Mist or Ewe with a pluggable wire codec.

## Two layers, one runtime

beryl ships one runtime and two ways to program it.

The **channel layer** (`beryl/channel`) is the recommended default. Register a
list of channel handlers. Each handler has a topic pattern and a typed `join`
callback. The layer routes each event to the channel that owns the topic:

```gleam
let assert Ok(#(sockets, spec)) =
  channel.child_spec(
    beryl.config(wire.phoenix_codec()),
    handlers: [lobby.channel(), rooms.channel(), documents.channel()],
  )
```

**Raw app-side dispatch** (`beryl`) is the core API. Pass one `init` and
`update` pair to `beryl.child_spec`. Use this API for one topic family or for
full control of routing and effect order:

```gleam
let assert Ok(#(sockets, spec)) =
  beryl.child_spec(
    beryl.config(wire.phoenix_codec()),
    init: init,
    update: update,
  )
```

Both APIs use the same runtime, wire codec, presence, PubSub, and abuse
controls. Add either child specification to your application's supervision
tree. The channel layer uses only beryl's public API. See
[Choose an API](/choosing-an-api/) for a comparison.

## Design principles

### Type safety first

beryl does not erase typed socket state to `Dynamic`. It does not use unchecked
coercion. With the channel layer, each channel defines private state and
server-side message types. The channel keeps these types inside its closures,
so unrelated channels can use one handler list. With raw dispatch, your socket
app defines one `Model` type and one `update` function. The Gleam compiler
checks each branch:

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

Each `beryl.Sockets` handle identifies one router actor and one actor for each
connected socket. The socket actor owns that socket's model and runs its
callbacks, while the router maintains the socket and topic indexes. A separate
OTP actor manages the presence CRDT. PubSub uses Erlang `pg`.

### CRDT-backed presence

Presence uses an **add-wins observed-remove set** (AWORSet) with causal context.
This CRDT resolves concurrent joins and leaves across Erlang nodes.

### Focused dependencies

The core library depends on `gleam_stdlib`, `gleam_erlang`, `gleam_otp`,
`gleam_json`, `gleam_crypto`, `lattice_presence`, and `palabres`. A WebSocket
transport such as `beryl_mist` adds `mist` and `gleam_http`. The core package
includes `beryl/channel`. beryl does not require an external message broker or
database.

### Phoenix wire protocol compatibility

The built-in `wire.phoenix_codec()` uses the Phoenix Channels JSON array
format: `[join_ref, ref, topic, event, payload]`. Existing Phoenix client
libraries can use this format. The
[Coming from Phoenix](/guides/coming-from-phoenix/) guide compares Phoenix
modules, callbacks, and assigns with both beryl APIs.

## Next steps

- [Choose an API](/choosing-an-api/) — channel layer or raw dispatch
- [Quick Start](/quick-start/) — get a working server in minutes
- [Channels guide](/guides/channels/) — handler tables, typed state, actions, and lifecycle
- [Dispatch guide](/guides/dispatch/) — route topics, messages, and close events in one app
- [Supervision guide](/guides/supervision/) — production startup with OTP supervision
- [Error Handling guide](/guides/error-handling/) — rejected joins, rate limits, and more
- [Troubleshooting](/troubleshooting/) — symptom-first diagnostics
