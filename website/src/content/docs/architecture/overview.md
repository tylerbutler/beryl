---
title: Architecture Overview
---

beryl is organized into several layers, each building on the one below it.

## Layer diagram

```
┌─────────────────────────────────────────┐
│           WebSocket Transport           │
│         (beryl/transport/mist)          │
├─────────────────────────────────────────┤
│            Wire Protocol                │
│            (beryl/wire)                 │
├─────────────┬───────────────────────────┤
│  Channels   │   Presence    │  Groups   │
│  (beryl/    │   (beryl/     │  (beryl/  │
│   channel)  │    presence)  │   group)  │
├─────────────┴───────────────┴───────────┤
│        Coordinator (OTP actor)          │
│        (beryl/coordinator)              │
├─────────────────────────────────────────┤
│            PubSub (pg)                  │
│          (beryl/pubsub)                 │
└─────────────────────────────────────────┘
```

## Core components

### PubSub (`beryl/pubsub`)

The foundation layer. Uses Erlang's `pg` module for distributed process groups. Processes subscribe to topics and receive broadcast messages. Works across Erlang cluster nodes automatically.

```gleam
let assert Ok(ps) = pubsub.start(pubsub.default_config())
pubsub.subscribe(ps, "room:lobby")
pubsub.broadcast(ps, "room:lobby", "event", payload)
```

### Coordinator (`beryl/coordinator`)

The central OTP actor managing all channel state:

- **Handler registry** — Maps topic patterns to channel handlers
- **Socket tracking** — Tracks connected sockets, their send functions, and subscribed topics
- **Topic subscriptions** — Maps topics to sets of subscriber socket IDs
- **Message routing** — Decodes wire protocol messages and dispatches to handlers
- **Heartbeat enforcement** — Periodic timer evicts sockets that miss heartbeats

The coordinator uses type erasure to store handlers with different assigns types in a single registry.

### Channels (`beryl/channel`)

The user-facing API for defining message handlers. Channels are built with a builder pattern:

```gleam
channel.new(join_handler)
|> channel.with_handle_in(message_handler)
|> channel.with_handle_binary(binary_handler)
|> channel.with_terminate(cleanup_handler)
```

Each channel is parameterized by an `assigns` type that provides compile-time safety for per-socket state.

### Presence (`beryl/presence`)

Two-layer design:

- **`beryl/presence`** — OTP actor wrapping an add-wins observed-remove CRDT. Handles track/untrack calls, periodically broadcasts state via PubSub for cross-node replication, exposes `State`/`Diff` aliases for advanced APIs, and fires `on_diff` callbacks when merges produce changes.

### Groups (`beryl/group`)

Named collections of topics managed by an OTP actor:

```gleam
let assert Ok(groups) = group.start()
let assert Ok(Nil) = group.create(groups, "team:eng")
let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
let assert Ok(Nil) = group.add(groups, "team:eng", "room:backend")

// Broadcast to all topics in the group
group.broadcast(groups, channels, "team:eng", "announce", payload)
```

### Supervisor (`beryl/supervisor`)

Optional OTP supervision tree for all beryl subsystems:

```gleam
import beryl
import beryl/supervisor
import beryl/wire
import gleam/option.{None, Some}

let config = supervisor.SupervisedConfig(
  channels: beryl.config(wire.phoenix_codec()),
  presence: Some(presence.default_config("node1")),
  groups: True,
)
let assert Ok(supervised) = supervisor.start(config)
// supervised.channels, supervised.presence, supervised.groups
```

Uses **rest-for-one** strategy with the child order: coordinator → presence → groups. A coordinator crash restarts all downstream children to maintain consistency. `child_spec/1` allows embedding the beryl subtree inside a larger application supervisor.

### Wire Protocol (`beryl/wire`)

Pluggable text/binary frame encoding and decoding. The built-in `wire.phoenix_codec()` handles:

- Message parsing: `[join_ref, ref, topic, event, payload]` arrays
- Reply encoding with status (`ok`/`error`) and response payload
- Server push messages (no ref)
- Heartbeat replies
- Structural dispatch for join, leave, heartbeat, and user events

### WebSocket Transport (`beryl/transport/mist`)

Integrates directly with Mist to handle WebSocket connections:

1. Generates a unique socket ID per connection
2. Registers the socket's send function with the coordinator
3. Routes incoming text frames through the configured codec
4. Routes binary frames through the codec when configured, or to raw binary channel handlers otherwise
5. Notifies the coordinator on connection close

### Topic (`beryl/topic`)

Topic pattern matching for channel routing:

- **Exact** — `"room:lobby"` matches only `"room:lobby"`
- **Wildcard** — `"room:*"` matches any topic starting with `"room:"`
- Utilities: `segments`, `namespace`, `from_segments`, `validate`, `extract_id`

### Socket (`beryl/socket`)

Opaque type representing a connected client with typed state:

- `id(socket)` — Get the socket ID
- `get_assigns(socket)` / `set_assigns(socket, assigns)` — Typed per-socket state
- `map_assigns(socket, fn)` — Transform assigns to a different type
- Internal: transport access, metadata storage
