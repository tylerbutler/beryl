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

1. **Type-safe channel handlers** — Channel callbacks should be parameterized by their socket state type (`assigns`), catching misuse at compile time rather than runtime.
2. **Phoenix wire protocol compatibility** — Reuse the proven `[join_ref, ref, topic, event, payload]` JSON format so existing client libraries (phoenix.js, etc.) work without modification.
3. **Distributed by default** — Pub/sub and presence should work across BEAM cluster nodes out of the box via Erlang's `pg` module.
4. **Minimal, composable API** — Each subsystem (channels, presence, groups, pub/sub) should be independently usable and opt-in.
5. **Framework agnostic** — Core library has no HTTP framework dependency; transport adapters (starting with Wisp) are separate modules.

## Non-Goals

- **Client-side library** — Beryl is server-side only. Clients use existing Phoenix-compatible JavaScript/TypeScript libraries.
- **Persistence layer** — Presence state is in-memory (CRDT). Durable storage is the application's responsibility.
- **Authentication framework** — Beryl provides hooks for auth in channel join callbacks but does not implement auth itself.
- **HTTP routing** — Beryl handles the WebSocket upgrade and message routing; HTTP request routing is left to the host framework.

## Target Users

- **Gleam developers** building real-time web applications on BEAM.
- **Elixir teams** adopting Gleam incrementally who need real-time features callable from both languages (via the Levee integration layer).
- **Library authors** building higher-level real-time abstractions (e.g. collaborative editing, live dashboards) on BEAM.

## Architecture

### System Layers

```
┌─────────────────────────────────────────────────────────┐
│  Application Layer                                      │
│  User-defined channel handlers with typed assigns       │
├─────────────────────────────────────────────────────────┤
│  Channel System                                         │
│  Coordinator · Groups · Wire Protocol                   │
├─────────────────────────────────────────────────────────┤
│  Distributed Systems                                    │
│  PubSub (pg) · Presence (CRDT actor)                    │
├─────────────────────────────────────────────────────────┤
│  Transport                                              │
│  Wisp WebSocket adapter · Socket abstraction            │
└─────────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Type erasure via FFI for handler storage** | Allows a single coordinator to store handlers with different `assigns` types while preserving compile-time safety at the handler definition site. |
| **Pure CRDT for presence state** | The `beryl/presence/state` module is a pure data structure (add-wins observed-remove set with causal context). This makes it testable in isolation and separable from the OTP actor that wraps it. |
| **Phoenix wire format** | Proven at scale; avoids inventing a new protocol; enables client-library reuse. |
| **pg-based PubSub** | Erlang's `pg` module provides distributed process groups with no external dependencies, automatic cluster membership, and battle-tested reliability. |
| **Coordinator as central OTP actor** | Single actor manages the pattern registry, socket tracking, topic subscriptions, and per-socket/per-topic state. Simplifies consistency at the cost of serialized coordination (acceptable for control-plane operations). |

## Functional Requirements

### FR-1: Channel System

#### FR-1.1: Channel Definition

Developers define channels by providing callback functions:

- **`join(topic, payload, context)`** — Called when a client requests to join a topic. Returns `JoinOk(assigns)` with optional reply payload, or `JoinError` with error details.
- **`handle_in(event, payload, context)`** — Called when a client sends a message on a joined topic. Returns `NoReply`, `Reply`, `Push` (server-initiated event), or `Stop`.
- **`handle_info(message, context)`** — Called when the channel process receives an OTP message. Same return types as `handle_in`.
- **`terminate(reason, context)`** — Called on channel leave or socket disconnect.

All callbacks receive a `SocketContext` containing the socket ID, current topic, current assigns, and a send function.

#### FR-1.2: Topic Pattern Matching

Channels are registered with topic patterns:

- **Exact**: `"room:lobby"` — matches only that topic.
- **Wildcard**: `"room:*"` — matches any topic starting with `"room:"`.

The coordinator matches incoming join requests to the first registered pattern. `extract_topic_id` extracts the wildcard portion (e.g. `"room:123"` → `"123"`).

#### FR-1.3: Socket Lifecycle

1. **Connect** — WebSocket established; coordinator assigns a cryptographically random socket ID.
2. **Join** — Client joins a topic; handler's `join` callback validates and initializes assigns.
3. **Message** — Client sends events; routed to `handle_in` for the appropriate topic.
4. **Leave** — Client leaves a topic; `terminate` called, subscription removed.
5. **Disconnect** — WebSocket closes; `terminate` called for all subscribed topics, socket fully removed.

#### FR-1.4: Broadcasting

- **`broadcast(channels, topic, event, payload)`** — Send to all subscribers of a topic.
- **`broadcast_from(channels, socket_id, topic, event, payload)`** — Send to all subscribers except the sender.
- **`push_to_socket(context, event, payload)`** — Direct push to the current socket.

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

- **`subscribe(pubsub, topic)`** / **`unsubscribe(pubsub, topic)`** — Manage subscriptions for the current process.
- **`broadcast(pubsub, topic, event, payload)`** — Send to all subscribers across the cluster.
- **`broadcast_from(pubsub, from_pid, topic, event, payload)`** — Send to all except the sender.
- **`local_broadcast(pubsub, topic, event, payload)`** — Send only to subscribers on the local node.
- **`subscribers(pubsub, topic)`** / **`subscriber_count(pubsub, topic)`** — Query subscribers.

PubSub is backed by Erlang's `pg` module with configurable scope atoms for isolation.

### FR-4: Groups

Named collections of topics that simplify multi-topic broadcasting:

- **`create(groups, name)`** / **`delete(groups, name)`** — Manage group lifecycle.
- **`add(groups, group, topic)`** / **`remove(groups, group, topic)`** — Manage group membership.
- **`broadcast(groups, channels, group, event, payload)`** — Broadcast to all topics in a group.
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

### FR-6: Transport — Wisp WebSocket Adapter

- **`upgrade(request, coordinator, config, next)`** — Middleware-style: intercepts requests matching the configured path, upgrades to WebSocket, falls through for non-matching requests.
- **`upgrade_connection(request, coordinator)`** — Direct upgrade for custom routing.

The adapter manages the full WebSocket lifecycle: connection, message routing to the coordinator, heartbeat handling, and graceful disconnection.

### FR-7: Levee Integration (Fluid Framework)

Optional integration module for Fluid Framework document collaboration via Elixir:

- **`document_channel`** — Pre-built channel handler for the `document:*` topic pattern implementing the Fluid Framework relay protocol (connect_document, submitOp, submitSignal, requestOps, noop).
- **`runtime`** — Elixir bridge functions for starting the channel system and forwarding connection lifecycle events from an Elixir host application.

## Non-Functional Requirements

### NFR-1: Performance

- The coordinator actor serializes control-plane operations (join/leave/register) but data-plane operations (broadcasting) use direct PID messaging via `pg`, avoiding the coordinator as a bottleneck for message delivery.
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

- Type-safe channel handlers catch assign type mismatches at compile time.
- Builder-pattern API for channel construction (`new` → `with_handle_in` → `with_terminate`).
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
| wisp | local path | WebSocket transport (requires PR #144) |

**Dev**: gleeunit >= 1.0.0

**Runtime**: Erlang/OTP >= 27.2.1, Gleam >= 1.14.0

## Current Status

| Feature | Status | Notes |
|---------|--------|-------|
| Channel system | **Complete** | Typed handlers, pattern matching, full lifecycle |
| Wire protocol | **Complete** | Phoenix-compatible JSON format |
| PubSub | **Complete** | pg-backed, local + distributed broadcast |
| Presence CRDT | **Complete** | Pure state module, property-based tested |
| Presence actor | **Complete** | Actor wraps CRDT; periodic delta replication via PubSub |
| Supervisor | **Complete** | Rest-for-one strategy, child_spec, validation |
| Groups | **Complete** | Named topic collections with broadcast |
| Wisp transport | **Complete** | WebSocket upgrade + lifecycle management |
| Levee integration | **Complete** | Document channel + Elixir runtime bridge |
| Binary transport | **Not started** | Text/JSON only currently |
| Rate limiting | **Not started** | No implementation |
| Presence persistence | **Not started** | In-memory only |

## Future Considerations

- **Presence replication via PubSub**: The `BroadcastTick` message in the presence actor is a placeholder. Full implementation would periodically extract deltas and broadcast via PubSub for cross-node convergence.
- **Transport plugins**: Additional adapters beyond Wisp (e.g. Mist, raw TCP).
- **Binary message support**: Support for binary WebSocket frames alongside JSON text frames.
- **Channel authentication middleware**: Composable auth hooks that run before `join` callbacks.
- **Telemetry/metrics integration**: Structured event emission for connection counts, message rates, presence changes.
- **Long-polling fallback**: For environments where WebSockets are unavailable.

## Glossary

| Term | Definition |
|------|-----------|
| **Assigns** | Per-socket, per-topic state managed by channel handlers. Typed generically. |
| **Coordinator** | Central OTP actor managing the channel registry, socket tracking, and message routing. |
| **CRDT** | Conflict-free Replicated Data Type. Beryl uses an add-wins observed-remove set for presence. |
| **pg** | Erlang's built-in process group module for distributed pub/sub. |
| **Replica** | A node's identity in the distributed presence system. Each node is a unique replica. |
| **Topic** | A string identifier (e.g. `"room:lobby"`) that clients subscribe to for receiving messages. |
| **Wire protocol** | The JSON message format exchanged over WebSocket connections. |
