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

The scope maps to a `pg` scope atom. Different scopes are completely isolated from each other.

:::danger[The scope must be a static, bounded deployment value]
The scope name is converted to an Erlang atom. Atoms are never
garbage-collected; exhausting the BEAM atom table crashes the VM. The scope
must be a static, bounded deployment or configuration value — never raw
user-derived, per-request, per-tenant, database-derived, or otherwise
unbounded high-cardinality runtime input. A deployment-controlled value is
acceptable only when validated or selected from a fixed bounded set.
:::

## Subscribing

The calling process receives `pubsub.Message` values when broadcasts are sent to the topic:

```gleam
// Subscribe the current process
pubsub.subscribe(ps, "room:lobby")

// Unsubscribe
pubsub.unsubscribe(ps, "room:lobby")
```

## Messages

Subscribers receive `Message` records:

```gleam
pub type Message {
  Message(
    topic: String,
    event: String,
    payload: json.Json,
    from: PubSubFrom,
  )
}

pub type PubSubFrom {
  System                    // Broadcast with no sender
  FromPid(Pid)              // Broadcast from a specific process
  FromSocket(Pid, String)   // Broadcast from a process, excluding a socket ID
}
```

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
let assert Ok(channels) =
  beryl.start_app(config, init: init, update: update)

// beryl.broadcast() now sends to all nodes automatically
beryl.broadcast(channels, "room:lobby", "event", payload)
```

## Next steps

- [Supervision guide](/guides/supervision/) — supervised startup and multi-node deployment checklist
- [Architecture overview](/architecture/overview/) — how PubSub fits into the beryl layer diagram
- [Troubleshooting](/troubleshooting/#pubsub-cluster-issues) — diagnosing cluster broadcast failures and diverging presence state
