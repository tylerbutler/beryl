---
marp: true
title: beryl architecture
theme: default
paginate: true
html: true
---

<script type="module">
  import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
  mermaid.initialize({ startOnLoad: true });
</script>

# beryl architecture

Type-safe realtime channels & presence on the BEAM

---

## What beryl is

- Phoenix-style channel system on OTP actors and Erlang `pg`
- Pluggable wire codec + WebSocket transport
- Channels, presence, and groups as independent domain actors
- Coordinator wires them together and enforces heartbeats
- PubSub is the only cross-node primitive

```mermaid
flowchart TB
  T["WebSocket Transport<br/>beryl/transport/mist"]
  W["Wire Protocol<br/>beryl/wire · beryl/wire/codec"]
  subgraph Domain["Channel domain"]
    C["Channels<br/>beryl/channel"]
    P["Presence<br/>beryl/presence"]
    G["Groups<br/>beryl/group"]
  end
  CO["Coordinator (OTP actor)<br/>beryl/coordinator"]
  PS["PubSub (Erlang pg)<br/>beryl/pubsub"]
  T --> W --> Domain --> CO --> PS
```

---

## Module map

| Module | Responsibility |
|---|---|
| `beryl` | Public entry-point: `config/1`, `start/1`, `register/3`, `broadcast/4` |
| `beryl/coordinator` | Central OTP actor: registry, socket tracking, routing, heartbeat |
| `beryl/pubsub` | Distributed pub-sub via Erlang `pg` |
| `beryl/presence` | Add-wins OR-set CRDT; track/untrack, cross-node diff broadcast |
| `beryl/wire` | Pluggable codec; ships `phoenix_codec()` |
| `beryl/transport/mist` | Mist WebSocket adapter; assigns IDs, routes frames |
| `beryl/group` | Named topic collections; supports grouped broadcast |
| `beryl/topic` | Topic pattern matching: exact and `"ns:*"` wildcards |

---

## Coordinator: the central actor

The coordinator is a **single OTP actor** that is the heart of beryl. It tracks:

- **Socket registry** — `socket_id → {assigns, send_fn, topics, last_heartbeat}`
- **Handler registry** — `topic_pattern → channel_handler`
- **PubSub subscriptions** — one pg group per joined topic
- **Heartbeat timer** — evicts stale sockets on deadline

All inbound frames, PubSub deliveries, and info messages pass through its mailbox sequentially. Because it is a single actor, no locks are needed for socket or topic state.

---

## Supervision tree

```mermaid
flowchart TB
  S["supervisor (rest-for-one)"]
  S --> CO["coordinator"]
  S --> PR["presence (optional)"]
  S --> GR["groups (optional)"]
  CO -. "crash restarts downstream" .-> PR
  PR -. .-> GR
```

- `rest-for-one`: coordinator crash restarts presence and groups
- Embeddable via `beryl/supervisor.child_spec/1`
- Presence and groups are optional; omit from config if unused

---

## Message lifecycle — connect

```mermaid
sequenceDiagram
  participant Client
  participant Mist as transport/mist
  participant Coord as coordinator
  Client->>Mist: WebSocket upgrade
  Mist->>Mist: generate socket id
  Mist->>Coord: register socket + send fn
  Coord-->>Mist: ack
```

The transport generates a 16-byte random ID (base16) and hands the socket and its send function to the coordinator for bookkeeping.

---

## Message lifecycle — join

```mermaid
sequenceDiagram
  participant Client
  participant Mist as transport/mist
  participant Wire as wire/codec
  participant Coord as coordinator
  participant Ch as channel handler
  Client->>Mist: text frame [join_ref, ref, topic, "phx_join", payload]
  Mist->>Wire: decode_message
  Wire-->>Coord: route_decoded(join)
  Coord->>Coord: match topic -> handler (registry)
  Coord->>Ch: join(socket, payload)
  Ch-->>Coord: Ok(assigns) / Error
  Coord->>Coord: subscribe socket to topic (pubsub.subscribe)
  Coord-->>Client: reply_json(ok/error)
```

---

## Message lifecycle — inbound event & broadcast

```mermaid
sequenceDiagram
  participant Client
  participant Coord as coordinator
  participant Ch as channel handler
  Client->>Coord: text frame [.., topic, event, payload]
  Coord->>Ch: handle_in(event, payload, socket)
  Ch-->>Coord: reply / noreply / push / stop
  Coord-->>Client: reply_json (when reply)
```

```mermaid
sequenceDiagram
  participant Origin as origin handler/app
  participant Coord as coordinator
  participant PS as pubsub (pg)
  participant Subs as subscriber sockets
  Origin->>Coord: broadcast(topic, event, payload)
  Coord->>PS: broadcast / broadcast_from (exclude origin)
  PS-->>Coord: deliver to each subscriber pid
  Coord-->>Subs: push(topic, event, payload) via send fn
```

---

## Heartbeat & terminate

```mermaid
sequenceDiagram
  participant Client
  participant Coord as coordinator
  Client->>Coord: [.., "phoenix", "heartbeat", {}]
  Coord-->>Client: heartbeat_reply
  Note over Coord: periodic timer checks last-seen
  Coord->>Coord: evict sockets past deadline
```

```mermaid
sequenceDiagram
  participant Client
  participant Mist as transport/mist
  participant Coord as coordinator
  participant Ch as channel handler
  Client->>Mist: socket close
  Mist->>Coord: socket closed(id)
  Coord->>Ch: terminate(reason, socket)
  Coord->>Coord: unsubscribe topics, drop socket state
```

---

## PubSub & distribution

```mermaid
flowchart LR
  subgraph Node1
    A[socket A] --- C1[coordinator]
  end
  subgraph Node2
    B[socket B] --- C2[coordinator]
  end
  C1 -- pg broadcast --> PG((pg group: topic))
  C2 -- subscribe --> PG
  PG -- deliver --> C2
```

- Built on Erlang `pg` — cluster-aware out of the box
- `broadcast_from` excludes the originating socket (load-bearing for correctness)
- Scoped by an Erlang atom; default scope is `beryl_pubsub`
- No extra message-bus infrastructure required

---

## Presence — CRDT replication

```mermaid
sequenceDiagram
  participant App
  participant Pres as presence actor
  participant PS as pubsub
  participant Remote as remote replica
  App->>Pres: track(topic, key, meta)
  loop every broadcast_interval
    Pres->>PS: broadcast CRDT state
  end
  Remote->>PS: its state
  PS-->>Pres: remote state
  Pres->>Pres: merge -> diff
  Pres-->>App: on_diff(diff)
```

- Add-wins OR-set CRDT via `lattice_presence/presence_state`
- Each node holds its own replica; merges converge without coordination
- `on_diff` fires on every local change or remote merge with a non-empty diff

---

## Wire & transport

```mermaid
flowchart LR
  FR["raw WS frame"] --> MI["transport/mist"]
  MI -->|text| CD["wire/codec"]
  MI -->|binary, no codec| RB["raw binary handler"]
  CD --> CO["coordinator"]
  CO --> EN["encode reply/push"] --> SF["socket send fn"] --> CL["client"]
```

- Phoenix wire format: `[join_ref, ref, topic, event, payload]`
- `Codec` is a data value — swap framing without touching coordinator or channel logic
- `phoenix_codec()` is the default; pass to `beryl.config/1`
- Binary frames bypass the codec when no `decode_binary` is configured

---

## Concurrency note

The coordinator is a **single OTP mailbox** — sequential processing with no locks needed.

- Broadcasts arrive as Erlang messages; tests must **select the exact message shape**
- Stale queued messages can cause nondeterministic test failures
- Drain messages your tests create; don't use broad "any message" selectors near PubSub assertions
- This is BEAM-native: supervised actors, pattern matching, no shared mutable state

---

## Where to start contributing

| Start here | Module | Purpose |
|---|---|---|
| 💡 Heart of beryl | `src/beryl/coordinator.gleam` | Actor, registry, message routing |
| 📨 Message flow | `src/beryl/transport/mist.gleam` | Connect → decode → route |
| 🔌 Channel API | `src/beryl/channel.gleam` | `join`, `handle_in`, `terminate` callbacks |
| 📡 Fan-out | `src/beryl/pubsub.gleam` | pg-based broadcast |
| 👥 Presence | `src/beryl/presence.gleam` | CRDT actor, track/untrack, diffs |
| 🔤 Framing | `src/beryl/wire.gleam` | Phoenix codec, encode/decode |

Start with `coordinator.gleam` — it is the single process that ties everything together.
Architecture docs live at `/architecture/` in the website.
