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

<!--
Speaker notes:
Opening frame. Beryl provides Phoenix-compatible realtime messaging and
presence as a type-safe Gleam library on the Erlang VM. Explain the deck in
this order: the purpose, the module map, the runtime effect interpreter, and
the connection lifecycle. The lifecycle includes connect, join, event,
broadcast, heartbeat, and close. Then explain distribution, presence, and how
to start contributing.
-->

---

## What beryl is

- App-side dispatch on OTP actors and Erlang `pg`: one `init`/`update` pair per app
- Pluggable wire codec + WebSocket transport (Mist, Ewe)
- Presence and groups are independent, app-owned OTP actors
- One runtime actor per app dispatches events and applies effects
- PubSub is the only cross-node primitive

```mermaid
flowchart TB
  T["WebSocket transports<br/>beryl_mist · beryl_ewe"]
  W["Wire Protocol<br/>beryl/wire · beryl/wire/codec"]
  R["Runtime & effect interpreter<br/>beryl/runtime (internal)"]
  E["App dispatch contract<br/>beryl/socket"]
  APP["your app's init/update"]
  PS["PubSub (Erlang pg)<br/>beryl/pubsub"]
  T --> W --> R
  R <--> E --> APP
  R --> PS
```

<!--
Speaker notes:
Read the diagram from top to bottom. A raw WebSocket frame enters the
transport. The wire codec converts bytes into typed messages. One OTP runtime
actor for each app sends typed `Input` values to the app's `update` function
and applies the returned `Effect` list. Beryl has no channel registry or
per-channel callback modules. One `update` function handles all relevant
topics and routes them by matching the topic string. PubSub is the only
primitive that crosses node boundaries. All layers above PubSub are local to
one node. Each box is an independent layer that you can inspect and test. The
runtime connects these layers.
-->

---

## Module map

| Module | Responsibility |
|---|---|
| `beryl` | Public entry-point: `config`, `child_spec`, `stop`, `broadcast` |
| `beryl/socket` | App dispatch contract: `Input`, `Next`, `Effect`, `Sender`, `ConnectInfo` |
| `beryl/runtime` | Internal OTP actor: socket tracking, dispatch, effect interpretation, heartbeat |
| `beryl/pubsub` | Distributed pub-sub via Erlang `pg`; typed `Subscriber(payload)` |
| `beryl/presence` | Add-wins OR-set CRDT; track/untrack, dirty full-state replication |
| `beryl/wire` | Pluggable codec; ships `phoenix_codec()` |
| `beryl_mist` / `beryl_ewe` | WebSocket adapters; assign socket ids, route frames |
| `beryl/group` | Named topic collections; supports grouped broadcast |
| `beryl/topic` | Topic pattern matching: exact, `"ns:*"` prefix, and segment wildcards |
| `beryl/bridge` | Forward an external actor's messages into one socket's `Info` events |

<!--
Speaker notes:
Use this table to find each responsibility. Two rows define most application
code. `beryl` is the public API. `beryl/socket` defines the application
contract: `Input` enters and `Effect` values leave. The internal
`beryl/runtime` module executes that contract. Applications do not import it,
but it is central to the architecture. The runtime uses PubSub for fan-out,
presence for membership, wire for framing, and the transport for the socket.
The application owns the presence actor, and the runtime borrows its handle.
`beryl/topic` is small but important. The app's `update` function uses it to
match a `Join` or `Message` topic against an application pattern.
-->

---

## The runtime: effect interpreter at the center

The runtime is a **single OTP actor**, one for each `Sockets` handle. It tracks:

- **Socket state**: `socket_id → {model, send_fn, joined topics, last_heartbeat}`
- **App contract**: calls `init`/`update` and applies the returned `Effect`s
- **PubSub subscriptions**: one pg group for each joined topic
- **Heartbeat timer**: removes stale sockets at the deadline

All inbound frames, PubSub deliveries, and `Info` messages pass through its
mailbox in sequence. Effects apply in strict list order within one turn.

<!--
Speaker notes:
This slide replaces the former coordinator and channel registry model. Beryl
does not need a registry because it does not look up per-topic handlers. One
`update` function handles each event for each socket on this runtime.

The runtime owns four types of state. Socket state contains the app's `model`,
not a Beryl `assigns` record. The app contract contains `init`, `update`, and
the `Effect` list that `update` returns. PubSub subscriptions receive
broadcasts. The heartbeat timer removes dead sockets.

One actor processes each mailbox message in sequence. This design avoids
mutexes and races in socket or topic state. Effect order equals wire order.
The actor performs bookkeeping, dispatch, and effect application. Applications
scale across nodes through `pg`.
-->

---

## Supervision: one supervised entry point

```mermaid
flowchart LR
  subgraph App["your application supervision tree"]
    AppSup["application supervisor"] --> Sup["Beryl subtree supervisor<br/>OneForOne"]
    Sup --> Rt["runtime<br/>Transient · significant"]
    Sup --> Lim["connection limiter (optional)"]
  end
```

- `child_spec` returns a child specification for the runtime subtree and a stable handle
- Add the subtree to *your* application supervisor
- Beryl **borrows** PubSub, presence, and groups. They are not children of this subtree.

<!--
Speaker notes:
`beryl.child_spec` provides one supervised entry point. It validates and builds the
OneForOne subtree (runtime as the significant, transient child, plus an
optional connection limiter sibling), then hands back a
`ChildSpecification` that the caller passes to `static_supervisor.add`. The
application supervisor owns the lifecycle. Presence, PubSub, and groups are
not part of this tree. The application starts and owns them, and the runtime
borrows their handles. `beryl.stop` terminates only Beryl's subtree. It does
not terminate the PubSub instance, presence actor, or group actors.
-->

---

## Message lifecycle: connect

```mermaid
sequenceDiagram
  participant Client
  participant Transport as beryl_mist / beryl_ewe
  participant Runtime as runtime
  participant App as app init
  Client->>Transport: WebSocket upgrade
  Transport->>Transport: generate socket id + build ConnectSeed
  Transport->>Runtime: capture owner pid + admit_socket(...)
  Runtime->>App: init(ConnectInfo)
  App-->>Runtime: #(model, init effects)
```

The transport generates a 16-byte random id in base16 form. It gives the
socket, its send functions, and the connection metadata (`ConnectSeed`) to the
runtime. The runtime then calls the app's `init`.

<!--
Speaker notes:
Use this slide to define the pattern for the next lifecycle slides. A client
action enters through the transport. The transport creates a socket id and
builds `ConnectSeed` from the request path, query, headers, and any
`on_connect` metadata. It then registers the socket with the runtime.

The runtime calls the app's `init` with `ConnectInfo`. This value contains the
socket id, the seed, and a typed `Sender` for later server messages. `init`
returns the initial socket `model` and any immediate effects. A join has not
occurred. The runtime now tracks a connection and its model.
-->

---

## Message lifecycle: join

```mermaid
sequenceDiagram
  participant Client
  participant Transport as beryl_mist / beryl_ewe
  participant Wire as wire/codec
  participant Runtime as runtime
  participant App as app update
  Client->>Transport: text frame [join_ref, ref, topic, "phx_join", payload]
  Transport->>Wire: decode_text
  Wire-->>Transport: Inbound(Join)
  Transport->>Runtime: route_decoded(socket_id, join)
  Runtime->>App: update(model, Join(topic, payload, ref))
  App-->>Runtime: Next(model, [AcceptJoin(ref, reply)]) or [RejectJoin(ref, reason)]
  Runtime->>Runtime: apply effect, subscribe topic
  Runtime-->>Client: phx_reply ok / error
```

<!--
Speaker notes:
This slide has no visible prose. Explain the sequence during the talk. A join is the
first Phoenix-protocol message: the client sends a `phx_join` frame carrying
a `join_ref`, a `ref`, the target topic, and a payload. Trace each step. The
transport connection invokes the configured wire codec at the edge, which
converts the raw array into a typed decoded message. The transport then routes
that value to the runtime. The runtime delivers exactly one `Join` event to the app's
`update` function. It does not look up a registry because `update` handles
every topic itself, typically by pattern-matching the topic string. The
app answers with `AcceptJoin`, which subscribes the socket to the topic's pg
group and sends an ok reply. `RejectJoin` sends an error reply and does not
create a subscription. If the join finishes the turn
without an answer, the runtime rejects it. This fail-closed behavior is part
of the design. Application code first runs at this point, and the runtime
creates the subscription state here. The next slides assume that the join
succeeded.
-->

---

## Message lifecycle: inbound event and broadcast

```mermaid
sequenceDiagram
  participant Client
  participant Runtime as runtime
  participant App as app update
  Client->>Runtime: text frame [.., topic, event, payload]
  Runtime->>App: update(model, Message(topic, event, payload, ref?))
  App-->>Runtime: Next(model, [ReplyOk/Push/Broadcast/...])
  Runtime->>Runtime: apply effects in list order
```

```mermaid
sequenceDiagram
  participant Origin as origin app/effect
  participant Runtime as runtime
  participant PS as pubsub (pg)
  participant Subs as subscriber sockets
  Origin->>Runtime: Broadcast / BroadcastFrom effect (or beryl.broadcast)
  Runtime->>PS: broadcast / broadcast_from (exclude origin)
  PS-->>Runtime: deliver to each subscriber pid
  Runtime-->>Subs: push(topic, event, payload) via send fn
```

<!--
Speaker notes:
Compare the two flows. The top diagram shows the inbound path. A client sends
an event on an already joined topic. The
runtime delivers a `Message` event to `update`, and the returned `Effect`
list controls the next operations. `ReplyOk` and `ReplyError` answer the
message ref. `Push` sends an unsolicited message to this socket.
`Broadcast` and `BroadcastFrom` send an event to a topic's subscribers.
`Stop` in `Next` closes the complete socket. Effects run in list order during
one actor turn, so list order is wire order. This rule matters when an
`AcceptJoin` precedes a `Push` in the same list.

The bottom diagram shows fan-out. A broadcast effect enters PubSub (`pg`),
which delivers it to each subscriber pid in the cluster. Each runtime then
pushes it to local sockets through their send functions. `BroadcastFrom`
excludes the originating socket. This rule prevents the sender from receiving
an echo of its own message and is necessary for correct behavior.
-->

---

## Heartbeat & close

```mermaid
sequenceDiagram
  participant Client
  participant Runtime as runtime
  Client->>Runtime: [.., "phoenix", "heartbeat", {}]
  Runtime-->>Client: heartbeat_reply
  Note over Runtime: periodic timer checks last-seen
  Runtime->>Runtime: evict sockets past deadline
```

```mermaid
sequenceDiagram
  participant Client
  participant Transport as beryl_mist / beryl_ewe
  participant Runtime as runtime
  participant App as app update
  Client->>Transport: socket close
  Transport->>Runtime: socket_disconnected(socket_id)
  loop each joined topic
    Runtime->>App: update(model, Closed(topic, reason))
  end
  Runtime->>Runtime: unsubscribe topics, drop socket state
```

<!--
Speaker notes:
Both diagrams show liveness and cleanup. In the top flow, Phoenix clients send
a periodic `heartbeat` on the special `"phoenix"` topic. The runtime replies
and records the last-seen time. A separate timer checks tracked sockets and
removes each socket that passes its deadline. This process detects clients
that lose their network connection or close without a clean disconnect.

The bottom flow covers clean closes, crashes, kicks, and timeouts. When a
socket connection ends, the runtime sends `Closed(topic, reason)` to `update`
for each joined topic. This event replaces the former `terminate` callback.
Application code can remove per-topic model state. The runtime then
unsubscribes and removes the socket. Both flows preserve one invariant: a dead
socket does not remain subscribed to a pg group. Broadcasts therefore do not
target closed connections.
-->

---

## PubSub & distribution

```mermaid
flowchart LR
  subgraph Node1
    A[socket A] --- R1[runtime]
  end
  subgraph Node2
    B[socket B] --- R2[runtime]
  end
  R1 -- pg broadcast --> PG((pg group: topic))
  R2 -- subscribe --> PG
  PG -- deliver --> R2
```

- Built on Erlang `pg` through a typed `Subscriber(payload)`; it works across the cluster
- `broadcast_from`/`BroadcastFrom` excludes the originating socket, which preserves correct behavior
- Scoped by an Erlang atom; default scope is `beryl_pubsub`
- No extra message-bus infrastructure required

<!--
Speaker notes:
Socket A on Node1 and socket B on Node2 join the same logical topic. A pg group
spans both nodes. When Node1 broadcasts, pg delivers the message to
subscribers on each node. Node2's runtime receives it and pushes it to socket
B.

This design does not require an external broker such as Redis or NATS. `pg`
ships with the BEAM and operates across connected nodes. Subscriptions use a
typed `Subscriber(payload)` handle with `pubsub.subscriber`, `join`, and
`leave`. The underlying pg operations remain the same.

Repeat the originating-socket exclusion rule from the previous slide. Also
explain the scope atom. Erlang atoms provide namespaces for groups, and the
default scope is `beryl_pubsub`. This permits multiple Beryl instances to
coexist. Do not derive the scope from user input because the VM does not
garbage-collect atoms.
-->

---

## Presence: CRDT replication

```mermaid
sequenceDiagram
  participant App as app update
  participant Worker as app presence worker
  participant Runtime as runtime
  participant Pres as presence actor
  participant PS as pubsub
  participant Remote as remote replica
  App->>Worker: nonblocking track / untrack command
  Worker->>Pres: track / untrack / list
  Worker->>Runtime: broadcast after completion
  loop every broadcast_interval
    Pres->>PS: broadcast CRDT state
  end
  Remote->>PS: its state
  PS-->>Pres: remote state
  Pres->>Pres: merge -> diff
  Pres-->>App: on_diff(diff) (optional)
```

- Add-wins OR-set CRDT via `lattice_presence/presence_state`
- App-owned actor: started and supervised separately
- Synchronous presence calls stay outside the shared runtime

<!--
Speaker notes:
Presence reports who is connected across the cluster. It stays consistent
without a central coordinator or database. Each node runs a presence actor
that holds one replica of an add-wins OR-set CRDT from `lattice_presence`.
The application starts and supervises this actor outside Beryl's subtree.

Public presence calls are synchronous. An application-owned worker performs
them outside the shared socket runtime and then broadcasts the result. On a
timer, the presence actor broadcasts its state through PubSub. It also merges
states from remote replicas. CRDT merges are commutative and idempotent.
Therefore, replicas converge when messages arrive in different orders or more
than once. The system does not need locks, a leader, or application conflict
resolution.

The design defers the asynchronous presence read-model and effect work as one
bundle. It does not expose a partial runtime feature that blocks the shared
actor.
-->

---

## Wire & transport

```mermaid
flowchart LR
  FR["raw WS frame"] --> MI["beryl_mist / beryl_ewe"]
  MI -->|text| CD["configured wire/codec"]
  MI -->|binary + decoder| CD
  MI -->|binary, no decoder| RB["raw Binary event fan-out"]
  CD -->|route_decoded / route_decoded_binary| RT["runtime"]
  RB -->|route_binary| RT
  RT --> EN["encode reply/push"] --> SF["socket send fn"] --> CL["client"]
```

- Phoenix wire format: `[join_ref, ref, topic, event, payload]`
- `Codec` is a data value; change the framing without changing the runtime or your `update`
- `beryl.config(codec)` requires an explicit codec; `phoenix_codec()` is the built-in Phoenix option
- Transports monitor the runtime pid and close the connection if it goes down

<!--
Speaker notes:
Follow the diagram from left to right. A raw frame enters the Mist or Ewe
transport, which selects a path for the frame type. Text frames use the
codec's text decoder. Binary frames use its binary decoder when one exists and
retain binary telemetry classification through `route_decoded_binary`. A
codec without a binary decoder uses the raw `Binary` event path. For outbound
data, the same codec encodes runtime replies and pushes. The runtime then gives
them to the socket's send function.

`Codec` is a data value, not fixed runtime logic. An application can change
framing without changing the runtime or application code. Beryl has no
implicit wire default. Callers pass a codec to `beryl.config`. Use
`wire.phoenix_codec()` for Phoenix JSON and V2 binary compatibility.

Transports monitor the runtime pid through `transport.runtime_pid` and pass
that exact pid to `transport.admit_socket`. A restart, identity mismatch, or
failed registration closes the WebSocket. The transport does not attach the
socket to the replacement runtime.
-->

---

## Concurrency note

The runtime uses a **single OTP mailbox**. It processes messages in sequence
and does not need locks.

- Broadcasts arrive as Erlang messages; tests must **select the exact message shape**
- Stale queued messages can cause nondeterministic test failures
- Drain messages that your tests create. Do not use broad "any message"
  selectors near PubSub assertions.
- This is BEAM-native: supervised actors, pattern matching, no shared mutable state

<!--
Speaker notes:
This slide gives architecture information and test guidance. One mailbox
processes messages in sequence without locks. Effect order equals wire order.

Broadcasts and pushes arrive as ordinary Erlang messages in a process
mailbox. A test must select the exact expected message shape. A broad
"any message" selector can consume a stale message from an earlier action.
The test can then fail intermittently. Drain the messages that each test
creates, and match the expected message shape. Mailbox state is the most
common source of intermittent test failures in this codebase.
-->

---

## Where to start contributing

| Start here | Module | Purpose |
|---|---|---|
| 💡 Public surface | `src/beryl.gleam` | `config`, `child_spec`, `stop`, broadcast helpers |
| 🔌 Dispatch contract | `src/beryl/socket.gleam` | `Input`, `Next`, `Effect`, `Sender`, `ConnectInfo` |
| ⚙️ Heart of beryl | `src/beryl/runtime.gleam` | Actor, dispatch, effect interpreter, heartbeat (internal) |
| 📨 Message flow | `packages/beryl_mist/src/beryl_mist.gleam` | Connect → decode → route |
| 📡 Fan-out | `src/beryl/pubsub.gleam` | pg-based broadcast, typed `Subscriber` |
| 👥 Presence | `src/beryl/presence.gleam` | CRDT actor, track/untrack, diffs |
| 🔤 Framing | `src/beryl/wire.gleam` | Phoenix codec, encode/decode |

Start with `beryl.gleam` and `beryl/socket.gleam` for the public contract.
Then read `runtime.gleam`. This single process connects all components.
The website contains architecture documents under `/architecture/`.

<!--
Speaker notes:
Use the closing slide to give specific next steps. The table starts with the
files that give a new contributor the most context. `beryl.gleam` contains
the public entry points. `socket.gleam` contains the contract that `update`
implements. Together, they define the public dispatch API.

Then read `runtime.gleam`. It connects all other parts, although applications
do not import it. Next, select a subject: transport for the connection
lifecycle, PubSub for fan-out, presence for the CRDT, or wire for framing.
The website has more architecture documents under `/architecture/`, including
`/architecture/runtime`. End the talk and invite questions.
-->
