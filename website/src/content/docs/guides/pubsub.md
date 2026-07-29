---
title: PubSub
---

beryl's PubSub layer provides distributed publish/subscribe messaging built on Erlang's `pg` (process groups) module.

PubSub is generic over its payload type: a `PubSub(payload)` carries values of whatever type you choose, and every broadcast and subscribe function is typed against it. beryl's own channel broadcasts use `PubSub(json.Json)`.

## Starting PubSub

```gleam
import beryl/pubsub

// Default scope ("beryl_pubsub")
let ps = pubsub.start(pubsub.default_config())

// Custom scope (isolates process groups)
let ps = pubsub.start(pubsub.config_with_scope("my_app_pubsub"))
```

The payload type is inferred from how you use `ps`. Annotate it when you want it pinned explicitly:

```gleam
let ps: pubsub.PubSub(json.Json) = pubsub.start(pubsub.default_config())
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

Subscribers receive `Message(payload)` records:

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

`FromSocket` carries both the sending process PID and a socket ID to exclude. Receiving coordinators use this to suppress delivery to the named socket, so that `beryl.broadcast_from` correctly excludes the sender across cluster nodes.

### Receiving messages with `selecting`

`pg` tracks bare `Pid`s, so a broadcast arrives as a **raw process message** rather than through a typed `Subject`. Use `pubsub.selecting` to recover it — it is the only supported way to turn that raw shape back into a `Message(payload)`:

```gleam
import gleam/erlang/process

pub type AppMessage {
  RemoteBroadcast(pubsub.Message(json.Json))
}

let selector =
  process.new_selector()
  |> process.select(my_subject)
  |> pubsub.selecting(RemoteBroadcast)
```

:::danger[Never match on the raw message yourself]
Do not build your own `select_record` matcher for `Message` or coerce the raw
term. `selecting` is the one place that knows the record's runtime shape; going
around it means a change to that shape becomes a silent mis-parse in your code.
:::

### The frozen wire contract

`Message` is sent **raw between nodes** via `pg`, so for any given `payload` type its runtime shape — the record tag and its four fields, in order — is a frozen wire contract, not just a source-level API. A rolling cluster upgrade must never mis-parse a frame from an older node. The same applies to `PubSubFrom`.

Because payloads travel as native BEAM terms rather than a self-describing format like JSON, evolving the shape of *your own* `payload` type is also a wire change. Version it yourself (for example with an explicit `v` field) if it has to change across a rolling upgrade.

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
  process.self(),   // sending coordinator process
  socket_id,        // socket ID to exclude on receiving coordinators
  "room:lobby",
  "new_message",
  json.string("hello"),
)

// Broadcast to local node only
pubsub.local_broadcast(ps, "room:lobby", "new_message", json.string("hello"))
```

Use `broadcast_from_socket` when you need to broadcast to all subscribers across a cluster while excluding one specific socket — even if that socket's coordinator is on a different node. `beryl.broadcast_from` calls this internally.

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
import beryl/supervisor
import beryl/wire
import gleam/otp/static_supervisor

let ps = pubsub.start(pubsub.default_config())

let beryl_config =
  supervisor.config(beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps))

let assert Ok(_root) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(supervisor.start(beryl_config))
  |> static_supervisor.start()

let channels = supervisor.channels(beryl_config)

// beryl.broadcast() now sends to all nodes automatically
beryl.broadcast(channels, "room:lobby", "event", payload)
```

## Next steps

- [Supervision guide](/guides/supervision/) — supervised startup and multi-node deployment checklist
- [Architecture overview](/architecture/overview/) — how PubSub fits into the beryl layer diagram
- [Troubleshooting](/troubleshooting/#pubsub-cluster-issues) — diagnosing cluster broadcast failures and diverging presence state
