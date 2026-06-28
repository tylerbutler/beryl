---
title: PubSub & Distribution
---

## Foundation

Beryl's PubSub layer is built on Erlang's built-in [`pg`](https://www.erlang.org/doc/man/pg.html) module (process groups). When a process subscribes to a topic, it joins a named `pg` group scoped to the PubSub instance. When a broadcast is sent, beryl looks up all members of that group and delivers the message to each one.

Because `pg` is cluster-aware, this works transparently across nodes in an Erlang cluster — a process on Node A subscribing to `"room:lobby"` will receive broadcasts from Node B without any additional configuration.

Each PubSub instance is isolated by a **scope** (an Erlang atom). The default scope is `beryl_pubsub`; use `config_with_scope/1` to create isolated namespaces.

## The FFI Boundary

The Gleam module `beryl/pubsub` delegates all low-level pg operations to `src/beryl_pubsub_ffi.erl` via `@external` declarations. The FFI file is intentionally minimal — it is a thin wrapper that maps Gleam calls directly to `pg` BIFs.

**Public surface of `beryl/pubsub`:**

| Function | Description |
|---|---|
| `start(config)` | Start a pg scope (idempotent — safe to call multiple times) |
| `subscribe(ps, topic)` | Subscribe the calling process to a topic |
| `unsubscribe(ps, topic)` | Remove the calling process from a topic |
| `broadcast(ps, topic, event, payload)` | Deliver to all subscribers on all nodes |
| `broadcast_from(ps, from, topic, event, payload)` | Deliver to all subscribers **except** `from` pid |
| `broadcast_from_socket(ps, from, except_socket_id, topic, event, payload)` | Deliver to all subscribers except `from`, carrying a socket exclusion hint |
| `local_broadcast(ps, topic, event, payload)` | Deliver to local-node subscribers only |
| `subscribers(ps, topic)` | Return all subscriber pids (all nodes) |
| `subscriber_count(ps, topic)` | Return subscriber count (all nodes) |

The `PubSubFrom` type tags each message with its origin so downstream receivers can inspect whether a message came from the system, a specific process, or a process with an associated socket:

```gleam
pub type PubSubFrom {
  System
  FromPid(Pid)
  FromSocket(Pid, String)
}
```

## Exclusion Semantics

`broadcast_from` and `broadcast_from_socket` implement **sender exclusion**: the originating process does not receive its own broadcast. This prevents a channel coordinator from echoing a message back to the socket that sent it.

- `broadcast_from(ps, from, ...)` — skips delivery to the process whose `Pid` matches `from`.
- `broadcast_from_socket(ps, from, except_socket_id, ...)` — also skips delivery to `from`, and carries `FromSocket(from, except_socket_id)` in the message so that any remote coordinator receiving it can optionally suppress re-delivery to a matching socket ID on their node.

:::caution[Regression-prone contract]
The exclusion behaviour is load-bearing for channel correctness. If the comparison `pid == from` is ever changed or skipped, senders will receive their own messages. Tests that cover `broadcast_from` exclusion must be preserved when refactoring the PubSub layer.
:::

## Distribution Diagram

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

When socket A sends a message on Node 1, its coordinator calls `broadcast_from`, which iterates the `pg` group members. Members on Node 2 receive the message via Erlang distribution — no extra message-bus infrastructure is required.

## Where this lives

| File | Role |
|---|---|
| `src/beryl/pubsub.gleam` | Public Gleam API — types, config, and all broadcast functions |
| `src/beryl_pubsub_ffi.erl` | Erlang FFI — thin `pg` wrappers called via `@external` |
