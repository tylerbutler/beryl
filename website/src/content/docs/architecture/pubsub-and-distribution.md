---
title: PubSub & Distribution
---

## Foundation

Beryl's PubSub layer is built on Erlang's built-in [`pg`](https://www.erlang.org/doc/man/pg.html) module (process groups). A process creates a typed `Subscriber(payload)`, joins it to topics, and receives broadcasts through that subscriber's typed `Subject`.

Because `pg` is cluster-aware, this works transparently across nodes in an Erlang cluster — a runtime on Node A subscribed to `"room:lobby"` will receive broadcasts from Node B without any additional configuration.

Each PubSub instance is isolated by a **scope** (an Erlang atom). The default scope is `beryl_pubsub`; use `config_with_scope/1` to create isolated namespaces.

## The FFI boundary

The Gleam module `beryl/pubsub` delegates all low-level pg operations to `packages/beryl/src/beryl_pubsub_ffi.erl` via `@external` declarations. The FFI file is intentionally minimal — it is a thin wrapper that maps Gleam calls directly to `pg` BIFs.

**Public surface of `beryl/pubsub`:**

| Function | Description |
|---|---|
| `default_config()` | Build the default `beryl_pubsub` scope |
| `config_with_scope(name)` | Build a config for a custom pg scope |
| `start(config)` | Start a pg scope (idempotent — safe to call multiple times) |
| `subscriber(ps)` | Create a typed `Subscriber(payload)` for the current process |
| `join(sub, topic)` | Join that subscriber to a topic |
| `leave(sub, topic)` | Leave a previously joined topic |
| `selecting(selector, sub, transform)` | Fold PubSub delivery into an actor or test `Selector` |
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

## Exclusion semantics

`broadcast_from` and `broadcast_from_socket` implement **sender exclusion**: the originating process does not receive its own broadcast. This prevents a runtime from echoing a message back to the socket that sent it.

- `broadcast_from(ps, from, ...)` — skips delivery to the process whose `Pid` matches `from`.
- `broadcast_from_socket(ps, from, except_socket_id, ...)` — also skips delivery to `from`, and carries `FromSocket(from, except_socket_id)` in the message so that any remote runtime receiving it can optionally suppress re-delivery to a matching socket id on that node.

:::caution[Regression-prone contract]
The exclusion behaviour is load-bearing for channel correctness. If the comparison `pid == from` is ever changed or skipped, senders will receive their own messages. Tests that cover `broadcast_from` exclusion must be preserved when refactoring the PubSub layer.
:::

## Distribution diagram

```mermaid
flowchart LR
  subgraph Node1
    A[socket A] --- R1[runtime]
  end
  subgraph Node2
    B[socket B] --- R2[runtime]
  end
  R1 -- pg broadcast --> PG((pg group: topic))
  R2 -- typed subscriber join --> PG
  PG -- deliver --> R2
```

When socket A sends a message on Node 1, its runtime calls `broadcast_from`, which iterates the `pg` group members. Members on Node 2 receive the message via Erlang distribution — no extra message-bus infrastructure is required.

## Trust model

All traffic arriving over Erlang distribution is treated as **fully trusted
cluster input**. There is no additional authentication layer between nodes:
the Erlang cookie and network controls are the security boundary.

A process on any peer node can:

- Subscribe to any `pg` group (PubSub topic) and receive all broadcasts.
- Inject messages that downstream runtimes will process as legitimate
  internal traffic.
- Inject reserved presence sync traffic, delivering false presence state to
  subscribers on all nodes. Ordinary WebSocket clients cannot reach these
  reserved internal topics — this vector is exclusive to trusted cluster peers.

**App-level authorization** — whether a join is accepted and how `update`
handles a client event — applies only to inbound WebSocket frames. It does
not screen messages that arrive via distribution.

Refer to the [Production Hardening guide](/guides/production-hardening/#erlang-cluster-security-boundary)
for the full cluster security requirements (cookie strength, TLS
distribution, EPMD port restrictions, and cluster isolation).

## Where this lives

| File | Role |
|---|---|
| `packages/beryl/src/beryl/pubsub.gleam` | Public Gleam API — types, config, `Subscriber(payload)`, and all broadcast functions |
| `packages/beryl/src/beryl_pubsub_ffi.erl` | Erlang FFI — thin `pg` wrappers called via `@external` |
