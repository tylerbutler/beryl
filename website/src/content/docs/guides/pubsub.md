---
title: PubSub
---

beryl's PubSub layer provides distributed publish/subscribe messaging built on Erlang's `pg` (process groups) module.

## Starting PubSub

```gleam
import beryl/pubsub

// Default scope ("beryl_pubsub")
let ps = pubsub.start(pubsub.default_config())

// Custom scope (isolates process groups)
let ps = pubsub.start(pubsub.config_with_scope("my_app_pubsub"))
```

The scope maps to a `pg` scope atom and identifies the PubSub instance at
runtime. Different scopes are completely isolated and can safely use different
payload types in the same process mailbox. Every handle using the same scope
must use the same payload type.

:::danger[The scope must be a static, bounded deployment value]
The scope name is converted to an Erlang atom. Atoms are never
garbage-collected; exhausting the BEAM atom table crashes the VM. The scope
must be a static, bounded deployment or configuration value — never raw
user-derived, per-request, per-tenant, database-derived, or otherwise
unbounded high-cardinality runtime input. A deployment-controlled value is
acceptable only when validated or selected from a fixed bounded set.
:::

## Subscribing

Create one typed subscriber in the process that owns the mailbox, join any
topics it needs, and fold PubSub delivery into that process's selector:

```gleam
let sub = pubsub.subscriber(ps)
pubsub.join(sub, "room:lobby")

let selector =
  process.new_selector()
  |> process.select(app_subject)
  |> pubsub.selecting(sub, RemoteBroadcast)

// Later:
pubsub.leave(sub, "room:lobby")
```

PubSub records arrive as raw BEAM messages, so `selecting` is the typed
validation boundary. It matches the subscriber's scope, allowing one process
to select subscribers with different payload types as long as their scopes
differ.

## Messages

Subscribers receive transparent `Message(payload)` records:

```gleam
pub type Message(payload) {
  Message(
    topic: String,
    event: String,
    payload: payload,
    from: PubSubFrom,
  )
}

pub type PubSubFrom {
  System                    // Broadcast with no sender
  FromPid(Pid)              // Broadcast from a specific process
  FromSocket(Pid, String)   // Broadcast from a process, excluding a socket ID
}
```

On the wire, the PubSub scope atom replaces the public record tag and is
followed by these four fields in order. This five-element tuple is a frozen
cross-node wire contract. Nodes using the old unscoped message shape do not
interoperate, so upgrade the cluster together when adopting this version.
Version changes to your own payload type explicitly when rolling upgrades must
accept old and new nodes concurrently.

`FromSocket` carries both the sending process PID and a socket ID to exclude. Receiving runtimes use this to suppress delivery to the named socket, so that `beryl.broadcast_from` correctly excludes the sender across cluster nodes.

## Broadcasting

```gleam
import gleam/json

// Broadcast to all subscribers (all nodes)
pubsub.broadcast(ps, "room:lobby", "new_message", json.string("hello"))

// Broadcast to all except the sender process
pubsub.broadcast_from(
  ps,
  process.self(),
  "room:lobby",
  "new_message",
  json.string("hello"),
)

// Broadcast to all except a specific socket ID (clustered "broadcast except this socket")
pubsub.broadcast_from_socket(
  ps,
  process.self(),   // sending runtime process
  socket_id,        // socket ID to exclude on receiving runtimes
  "room:lobby",
  "new_message",
  json.string("hello"),
)

// Broadcast to local node only
pubsub.local_broadcast(ps, "room:lobby", "new_message", json.string("hello"))
```

Use `broadcast_from_socket` when you need to broadcast to all subscribers across a cluster while excluding one specific socket — even if that socket's runtime is on a different node. `beryl.broadcast_from` calls this internally.

## Querying subscribers

```gleam
// All subscribers across all nodes
let pids = pubsub.subscribers(ps, "room:lobby")

// Count subscribers
let count = pubsub.subscriber_count(ps, "room:lobby")
```

## Distributed operation

Because PubSub is built on `pg`, it automatically works across connected Erlang nodes. When nodes join a cluster, their process groups are merged and messages are delivered to subscribers on all nodes — no configuration required.

## Integration with beryl channels

The channel system uses PubSub internally for distributed broadcasts when configured:

```gleam
import beryl
import beryl/wire

let ps = pubsub.start(pubsub.default_config())
let config = beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps)
let assert Ok(#(channels, spec)) =
  beryl.child_spec(config, init: init, update: update)
// Add `spec` to your application supervisor before using `channels`.

// beryl.broadcast() now sends to all nodes automatically
beryl.broadcast(channels, "room:lobby", "event", payload)
```

## Next steps

- [Supervision guide](/guides/supervision/) — supervised startup and multi-node deployment checklist
- [Architecture overview](/architecture/overview/) — how PubSub fits into the beryl layer diagram
- [Troubleshooting](/troubleshooting/#pubsub-cluster-issues) — diagnosing cluster broadcast failures and diverging presence state
