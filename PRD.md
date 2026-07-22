# Beryl — Product Requirements Document

## Overview

**Beryl** is a type-safe real-time channels and presence library for Gleam, targeting the Erlang (BEAM) runtime. It provides the building blocks for applications that need WebSocket-based bidirectional communication, distributed presence tracking, and topic-based publish/subscribe — all with Gleam's compile-time type safety guarantees.

Beryl draws architectural inspiration from Phoenix Channels (including wire-protocol compatibility) while being designed from the ground up as a standalone library that can integrate with any BEAM-based HTTP framework.

## Problem Statement

Building real-time features on the BEAM typically means either:

1. **Using Phoenix Channels directly** — tightly coupled to the Phoenix framework and written in Elixir, unavailable to Gleam applications.
2. **Rolling your own** — reimplementing channel multiplexing, presence tracking, and distributed pub/sub from scratch on top of raw WebSockets and OTP primitives.

Gleam's ecosystem lacks a dedicated real-time communication library. Developers building Gleam web applications (e.g. with Wisp) have no idiomatic way to add WebSocket channels, track online users, or broadcast events across a cluster.

## Goals

1. **Type-safe app dispatch** — Every socket routes through one app-supplied `update` function parameterized by the app's own `model` type, catching misuse at compile time rather than runtime.
2. **Phoenix wire protocol compatibility** — Reuse the proven `[join_ref, ref, topic, event, payload]` JSON format so existing client libraries (phoenix.js, etc.) work without modification.
3. **Distributed by default** — Pub/sub and presence should work across BEAM cluster nodes out of the box via Erlang's `pg` module.
4. **Minimal, composable API** — Each subsystem (channels, presence, groups, pub/sub) should be independently usable and opt-in.
5. **Framework agnostic** — Dispatch, presence, and PubSub logic stay separate from HTTP routing. The built-in WebSocket transport integrates directly with Mist.

## Non-Goals

- **Client-side library** — Beryl is server-side only. Clients use existing Phoenix-compatible JavaScript/TypeScript libraries.
- **Persistence layer** — Presence state is in-memory (CRDT). Durable storage is the application's responsibility.
- **Authentication framework** — Beryl provides hooks for auth (`on_connect`, and per-topic authorization in the app's `update`) but does not implement auth itself.
- **HTTP routing** — Beryl handles the WebSocket upgrade and message routing; HTTP request routing is left to the host framework.

## Target Users

- **Gleam developers** building real-time web applications on BEAM.
- **Elixir teams** adopting Gleam incrementally who need real-time features callable from both languages.
- **Library authors** building higher-level real-time abstractions (e.g. collaborative editing, live dashboards) on BEAM.

## Architecture

### System Layers

```
┌─────────────────────────────────────────────────────────┐
│  Application Layer                                      │
│  One `init`/`update` pair with a typed `model`           │
├─────────────────────────────────────────────────────────┤
│  Dispatch Runtime                                        │
│  Runtime actor (effect interpreter) · Groups · Wire      │
├─────────────────────────────────────────────────────────┤
│  Distributed Systems                                      │
│  PubSub (pg) · Presence (CRDT actor)                     │
├─────────────────────────────────────────────────────────┤
│  Transport                                                │
│  Mist/Ewe WebSocket adapter · Transport SPI              │
└─────────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **App-side dispatch** | The application supplies one `init`/`update` pair; the runtime routes every wire event to it and applies the returned effects. Each socket has a single `model`/`msg` type — no type erasure, no per-callback coercions. |
| **Pure CRDT for presence state** | The `lattice_presence/presence_state` module is a pure data structure (add-wins observed-remove set with causal context). This makes it testable in isolation and separable from the OTP actor that wraps it. |
| **Phoenix wire format** | Proven at scale; avoids inventing a new protocol; enables client-library reuse. |
| **pg-based PubSub** | Erlang's `pg` module provides distributed process groups with no external dependencies, automatic cluster membership, and battle-tested reliability. |
| **Runtime as central OTP actor** | Single actor per app dispatches wire events to `update` and interprets the returned effects, managing socket tracking, topic subscriptions, and per-socket/per-topic state. Simplifies consistency at the cost of serialized coordination (acceptable for control-plane operations). |

## Functional Requirements

### FR-1: App-Side Dispatch

#### FR-1.1: Dispatch Definition

Developers supply one `init`/`update` pair per app:

- **`init(info: ConnectInfo(msg))`** — Called once when a socket connects. Returns the initial `#(model, List(Effect))`.
- **`update(model, event: Event(msg))`** — Called for every event on the socket: `Join`, `Message`, `Binary`, `Closed`, or `Info`. Returns `Next(model, effects)` to continue, or `Stop(reason)` to tear the socket down.

An `update` call returns a `List(Effect)` — `AcceptJoin`/`RejectJoin`, `ReplyOk`/`ReplyError`, `Push`, `Broadcast`/`BroadcastFrom`, presence effects, or `KickTopic` — applied strictly in list order by the runtime.

#### FR-1.2: Topic Pattern Matching

Applications route topics themselves by matching the `topic: String` field of `Join`/`Message`/`Closed` events with `beryl/topic` patterns:

- **Exact**: `"room:lobby"` — matches only that topic.
- **Wildcard**: `"room:*"` — matches any topic starting with `"room:"`.

`topic.extract_id` extracts the wildcard portion (e.g. `"room:123"` → `"123"`).

#### FR-1.3: Socket Lifecycle

1. **Connect** — WebSocket established; the runtime assigns a cryptographically random socket ID and calls `init`.
2. **Join** — Client joins a topic; `update` receives a `Join` event and must answer with `AcceptJoin`/`RejectJoin`. An unanswered join is rejected automatically (fail closed).
3. **Message** — Client sends events; `update` receives a `Message` event for the joined topic.
4. **Leave/close** — Client leaves a topic, or the socket disconnects; `update` receives a `Closed` event for every affected topic, and topic/socket state is removed.

#### FR-1.4: Broadcasting

- **`beryl.broadcast(sockets, topic, event, payload)`** — Send to all subscribers of a topic.
- **`beryl.broadcast_from(sockets, except_socket_id, topic, event, payload)`** — Send to all subscribers except one socket.
- **`Push(topic, event, payload)`** effect — Direct push to the current socket's joined topic.

When PubSub is configured, broadcasts are distributed across the BEAM cluster.

### FR-2: Presence

#### FR-2.1: Tracking

- **`track(presence, topic, key, pid, meta)`** — Register a process as present on a topic with a key and arbitrary metadata.
- **`untrack(presence, topic, key, pid)`** — Remove a specific presence entry.
- **`untrack_all(presence, pid)`** — Remove all presence entries for a process.

#### FR-2.2: Querying

- **`list(presence, topic)`** — All presence entries for a topic.
- **`get_by_key(presence, topic, key)`** — Entries matching a specific key.
- **`get_diff(presence, topic)`** — Current diff (joins/leaves) since last query.

#### FR-2.3: CRDT Semantics

Presence state uses an **add-wins observed-remove set** with causal context:

- Concurrent joins and leaves resolve deterministically: **adds win**.
- Vector clocks track causality per replica.
- Cloud sets handle out-of-order delivery.
- Merge produces a diff (joins/leaves) for efficient notification.
- Replica lifecycle (up/down/remove) supports graceful cluster membership changes.

#### FR-2.4: Distributed Replication

When PubSub is configured, presence state replicates across nodes via periodic broadcast ticks. Each node maintains a full replica; merges are crdt-convergent.

### FR-3: PubSub

- **`subscriber(pubsub)`** — Obtain a typed `Subscriber(payload)` handle for the calling process; **`join(sub, topic)`** / **`leave(sub, topic)`** manage its subscriptions.
- **`broadcast(pubsub, topic, event, payload)`** — Send to all subscribers across the cluster.
- **`broadcast_from(pubsub, from_pid, topic, event, payload)`** — Send to all except the sender.
- **`local_broadcast(pubsub, topic, event, payload)`** — Send only to subscribers on the local node.
- **`subscribers(pubsub, topic)`** / **`subscriber_count(pubsub, topic)`** — Query subscribers.

PubSub is backed by Erlang's `pg` module with configurable scope atoms for isolation.

### FR-4: Groups

Named collections of topics that simplify multi-topic broadcasting:

- **`create(groups, name)`** / **`delete(groups, name)`** — Manage group lifecycle.
- **`add(groups, group, topic)`** / **`remove(groups, group, topic)`** — Manage group membership.
- **`broadcast(groups, sockets, group, event, payload)`** — Broadcast to all topics in a group.
- **`topics(groups, group)`** — List topics in a group.

### FR-5: Wire Protocol

JSON array format compatible with Phoenix Channels:

```
[join_ref, ref, topic, event, payload]
```

**System events**: `phx_join`, `phx_leave`, `phx_reply`, `phx_error`, `phx_close`, `heartbeat`.

**Reply format**:
```json
[join_ref, ref, topic, "phx_reply", {"status": "ok"|"error", "response": {...}}]
```

**Server push format** (no join_ref/ref):
```json
[null, null, topic, "custom_event", {...}]
```

### FR-6: Transport — Mist WebSocket Adapter

- **`upgrade(request, sockets, config, next)`** — Middleware-style: intercepts requests matching the configured path, upgrades to WebSocket, falls through for non-matching requests.
- **`upgrade_connection(request, sockets)`** — Direct upgrade for custom routing.

The adapter manages the full WebSocket lifecycle: connection, message routing to the runtime, heartbeat handling, and graceful disconnection.

## Non-Functional Requirements

### NFR-1: Performance

- The runtime actor serializes control-plane operations (join/leave/dispatch) but data-plane operations (broadcasting) use direct PID messaging via `pg`, avoiding the runtime as a bottleneck for message delivery.
- Presence CRDT merges are O(n) in the number of entries, suitable for typical presence workloads (hundreds to low thousands of concurrent users per topic).

### NFR-2: Reliability

- Built on OTP actors with supervision-ready design.
- CRDT-based presence is partition-tolerant and convergent — nodes that temporarily lose connectivity will reconcile state on reconnection.
- Socket IDs generated with `gleam/crypto` for uniqueness.

### NFR-3: Observability

- Configurable heartbeat interval for connection health monitoring.
- Subscriber counts queryable via PubSub API.
- Presence diffs available for change tracking.

### NFR-4: Developer Experience

- Type-safe app dispatch catches `model`/`msg` type mismatches at compile time.
- Builder-pattern `Config` API (`beryl.config` → `with_*` builders) for abuse controls and subsystem wiring.
- Sensible defaults (e.g. `default_config()`) with opt-in configuration.
- Errors modeled as Result types throughout.

## Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| gleam_stdlib | >= 0.44.0 | Standard library |
| gleam_erlang | >= 0.29.0 | Erlang interop, process management |
| gleam_otp | >= 0.12.0 | OTP actors (Subject, process) |
| gleam_json | >= 3.0.0 | Wire protocol encoding/decoding |
| gleam_crypto | >= 1.5.1 | Socket ID generation |
| mist | >= 6.0.0 and < 7.0.0 | WebSocket transport |

**Dev**: gleeunit >= 1.0.0

**Runtime**: Erlang/OTP >= 27.2.1, Gleam >= 1.14.0

## Current Status

| Feature | Status | Notes |
|---------|--------|-------|
| App-side dispatch | **Complete** | Typed `init`/`update`, effect list, full socket lifecycle |
| Wire protocol | **Complete** | Phoenix-compatible JSON format |
| PubSub | **Complete** | pg-backed, local + distributed broadcast, typed `Subscriber` |
| Presence CRDT | **Complete** | Pure state module, property-based tested |
| Presence actor | **Complete** | Actor wraps CRDT; periodic delta replication via PubSub |
| Supervision | **Complete** | `beryl.start` (standalone) and `beryl.child_spec` (embedded); OneForOne subtree, validation |
| Groups | **Complete** | Named topic collections with broadcast |
| Mist/Ewe transport | **Complete** | WebSocket upgrade + lifecycle management, no Wisp dependency |
| Binary transport | **Complete** | Raw BitArray frames via the `Binary` event |
| Rate limiting | **Complete** | Token bucket per socket/topic/join; configurable rate+burst |

## Future Considerations

- **Presence replication via PubSub**: The `BroadcastTick` message in the presence actor is a placeholder. Full implementation would periodically extract deltas and broadcast via PubSub for cross-node convergence.
- **Transport plugins**: Additional adapters beyond Mist, such as raw TCP.
- **Authentication middleware**: Composable auth hooks that run before a `Join` event reaches `update`.
- **Telemetry/metrics integration**: Structured event emission for connection counts, message rates, presence changes.
- **Long-polling fallback**: For environments where WebSockets are unavailable.

## Glossary

| Term | Definition |
|------|-----------|
| **Model** | Per-socket application state threaded through `update` calls via `Next`. Typed by the app. |
| **Runtime** | Central OTP actor (internal, `beryl/runtime`) dispatching wire events to `update` and interpreting the returned effects; manages socket tracking and message routing. |
| **CRDT** | Conflict-free Replicated Data Type. Beryl uses an add-wins observed-remove set for presence. |
| **pg** | Erlang's built-in process group module for distributed pub/sub. |
| **Replica** | A node's identity in the distributed presence system. Each node is a unique replica. |
| **Topic** | A string identifier (e.g. `"room:lobby"`) that clients subscribe to for receiving messages. |
| **Wire protocol** | The JSON message format exchanged over WebSocket connections. |
