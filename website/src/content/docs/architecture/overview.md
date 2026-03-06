---
title: Architecture Overview
---

beryl is organized into several layers, each building on the one below it.

## Layer diagram

```
┌─────────────────────────────────────────┐
│           WebSocket Transport           │
│       (beryl/transport/websocket)       │
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

### Presence (`beryl/presence`, `beryl/presence/state`)

Two-layer design:

- **`beryl/presence/state`** — Pure CRDT: add-wins observed-remove set with causal context (vector clocks + cloud sets). Supports `join`, `leave`, `merge`, `compact`, `replica_up/down`, and query operations. No side effects.

- **`beryl/presence`** — OTP actor wrapping the CRDT. Handles track/untrack calls, periodically broadcasts state via PubSub for cross-node replication, and fires `on_diff` callbacks when merges produce changes.

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

### Wire Protocol (`beryl/wire`)

JSON encoding and decoding for the Phoenix-compatible wire protocol. Handles:

- Message parsing: `[join_ref, ref, topic, event, payload]` arrays
- Reply encoding with status (`ok`/`error`) and response payload
- Server push messages (no ref)
- Heartbeat replies
- Dynamic-to-JSON conversion for payloads

### WebSocket Transport (`beryl/transport/websocket`)

Integrates with Wisp to handle WebSocket connections:

1. Generates a unique socket ID per connection
2. Registers the socket's send function with the coordinator
3. Routes incoming text frames through the wire protocol decoder
4. Routes binary frames directly to the coordinator
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
