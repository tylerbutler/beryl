---
title: PubSub
description: Publish typed messages to topic subscribers on one or more connected Erlang nodes.
---

beryl's PubSub API uses Erlang `pg` process groups. Publishers send messages
to a topic, and each process subscribed to that topic receives them.

## Starting PubSub

```gleam
import beryl/pubsub

// Default scope ("beryl_pubsub")
let ps = pubsub.start(pubsub.default_config())

// Custom scope (isolates process groups)
let ps = pubsub.start(pubsub.config_with_scope("my_app_pubsub"))
```

The scope maps to a `pg` scope atom and identifies the PubSub instance.
Different scopes are isolated and can use different payload types in one
process mailbox. All handles in one scope must use the same payload type.

:::danger[Use a fixed scope name]
The scope name is converted to an Erlang atom. Atoms are never
garbage-collected; exhausting the BEAM atom table crashes the VM. The scope
must be a fixed deployment or configuration value. Never use a value from a
request, tenant, database row, or any other source that can create unlimited
names. A deployment-controlled value is safe only when you validate it or
select it from a fixed set.
:::

## Subscribing

Create one typed subscriber in the process that owns the mailbox. Join the
required topics. Add PubSub delivery to the process selector:

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

PubSub records arrive as raw BEAM messages. `selecting` validates their types
and matches the subscriber scope. One process can select subscribers with
different payload types if their scopes differ.

## Message format

Subscribers receive typed `Message(payload)` records:

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

`FromSocket` contains the sender PID and a socket ID to exclude. Receiving
runtimes do not send the message to that socket. Thus,
`beryl.broadcast_from` excludes the sender across cluster nodes.

## Send broadcasts

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

Use `broadcast_from_socket` to send to all cluster subscribers except one
socket. The socket can be on another node. `beryl.broadcast_from` calls this
function.

## List subscribers

```gleam
// All subscribers across all nodes
let pids = pubsub.subscribers(ps, "room:lobby")

// Count subscribers
let count = pubsub.subscriber_count(ps, "room:lobby")
```

## Use PubSub across Erlang nodes

Erlang `pg` works across connected nodes. After your application establishes
Erlang distribution between the nodes, `pg` merges their process groups and
sends messages to subscribers across the cluster. beryl PubSub needs no
additional configuration, but it does not connect the nodes for you.

Automated tests currently exercise distributed behavior with multiple actors
on one BEAM node. [Issue #365](https://github.com/tylerbutler/beryl/issues/365)
tracks integration coverage across separate distributed Erlang nodes for
PubSub delivery and presence convergence.

## Use PubSub with beryl

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

- [Supervision guide](/guides/supervision/): supervised startup and multi-node deployment
- [Architecture overview](/architecture/overview/): PubSub's place in beryl
- [Troubleshooting](/troubleshooting/#broadcasts-fail-across-erlang-nodes): diagnose cluster broadcast failures and different presence state across nodes
