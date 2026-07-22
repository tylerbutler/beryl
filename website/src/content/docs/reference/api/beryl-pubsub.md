---
title: beryl/pubsub
description: PubSub - Distributed publish/subscribe using Erlang pg
---

PubSub - Distributed publish/subscribe using Erlang pg

 Provides topic-based pub/sub messaging backed by Erlang's built-in `pg`
 module. Subscribers are tracked by process group, so messages are delivered
 to all nodes in the cluster automatically.

 The payload is generic: `PubSub(payload)` and `Message(payload)` carry
 whatever Gleam type a given instance is started with. A broadcast sends
 that value as a native BEAM term — there is no encoding step, even across
 nodes, since Erlang's own distribution protocol marshals arbitrary terms
 for you. Reach for a `gleam/json` payload only when the data is also
 destined for a JSON-speaking client (e.g. relayed on to a WebSocket
 browser); payloads that never leave the cluster are cheaper and safer as
 plain Gleam types.

 ## Quick Start

 ```gleam
 let ps = pubsub.start(pubsub.default_config())
 pubsub.subscribe(ps, "room:lobby")
 pubsub.broadcast(ps, "room:lobby", "new_msg", "hello")

 // Receiving: fold `pubsub.selecting` into an actor's own `Selector`.
 // `RemoteBroadcast` here is the actor's own message constructor that
 // wraps an incoming `pubsub.Message(payload)`.
 let selector =
   process.new_selector()
   |> process.select(subject)
   |> pubsub.selecting(RemoteBroadcast)
 ```

## Types

### `Message`

A PubSub message delivered to subscribers.

 This type is intentionally transparent so subscribers can inspect the topic,
 event, payload, and sender metadata delivered to their process mailbox.

 ## Frozen wire contract

 `Message` is sent **raw between nodes** via `pg`, so its runtime shape —
 the record tag and its four fields, in this order — is a frozen wire
 contract, not just a source-level API, for any given `payload` type: a
 rolling cluster upgrade must never mis-parse a frame from an older node
 running the same payload type. The same applies to `PubSubFrom`.

 Because payloads travel as native terms rather than a self-describing
 format like JSON, evolving the *shape* of your own `payload` type is also
 a wire change — version it yourself (e.g. an explicit `v` field) if it
 needs to change across a rolling upgrade. Never construct or match on this
 type directly from a raw process message; use `selecting`, which is the
 one place that knows how to recover it safely.

```gleam
pub type Message(a) {
  Message(
    topic: String,
    event: String,
    payload: a,
    from: PubSubFrom
  )
}
```

### `PubSub`

A running PubSub instance.

 This handle is intentionally opaque so callers cannot forge pg scopes or
 depend on the runtime representation. `payload` fixes the Gleam type
 every `Message` broadcast through this instance carries.

```gleam
pub type PubSub(a)
```

### `PubSubConfig`

PubSub configuration.

 Build with `default_config` or `config_with_scope` so the underlying pg
 scope representation can evolve without exposing record fields.

```gleam
pub type PubSubConfig
```

### `PubSubFrom`

Identifies the sender of a broadcast.

 Part of the frozen wire contract described on `Message`.

```gleam
pub type PubSubFrom {
  System
  FromPid(process.Pid)
  FromSocket(
    process.Pid,
    String
  )
}
```

#### Constructors

##### `System`

Broadcast originated from the system (no sender pid)

##### `FromPid(process.Pid)`

Broadcast originated from a specific process

##### `FromSocket(
  process.Pid,
  String
)`

Broadcast originated from a process and should exclude a socket ID

## Functions

### `broadcast`

Broadcast a message to all subscribers of a topic (all nodes)

```gleam
pub fn broadcast(
  PubSub(a),
  String,
  String,
  a
) -> Nil
```

### `broadcast_from`

Broadcast a message to all subscribers except those from a specific pid

```gleam
pub fn broadcast_from(
  PubSub(a),
  process.Pid,
  String,
  String,
  a
) -> Nil
```

### `broadcast_from_socket`

Broadcast a message to all subscribers except a process, preserving a socket
 ID that receiving channel coordinators should exclude locally.

```gleam
pub fn broadcast_from_socket(
  PubSub(a),
  process.Pid,
  String,
  String,
  String,
  a
) -> Nil
```

### `config_with_scope`

Create a PubSub configuration with a custom scope name

 The scope name is converted to an Erlang atom via `binary_to_atom`.
 Atoms are never garbage-collected, so the scope name must be a
 **static, bounded deployment or configuration value** — never raw
 user-derived, per-request, per-tenant, database-derived, or otherwise
 unbounded high-cardinality runtime input. A deployment-controlled value
 is acceptable only when validated or selected from a fixed bounded set.
 A malicious or high-cardinality source can exhaust the BEAM atom table
 and crash the VM.

 ```gleam
 // Correct — static deployment constant
 pubsub.config_with_scope("my_app_pubsub")

 // Correct — deployment-controlled, selected from a fixed bounded set
 // pubsub.config_with_scope(config.pubsub_scope())

 // WRONG — never do this
 // pubsub.config_with_scope(user_request.tenant_id)
 // pubsub.config_with_scope(database_row.name)
 ```

```gleam
pub fn config_with_scope(String) -> PubSubConfig
```

### `default_config`

Create a default PubSub configuration with scope `beryl_pubsub`

```gleam
pub fn default_config() -> PubSubConfig
```

### `local_broadcast`

Broadcast a message to local subscribers only (current node)

```gleam
pub fn local_broadcast(
  PubSub(a),
  String,
  String,
  a
) -> Nil
```

### `selecting`

Add PubSub message delivery to a `Selector`, alongside a process's own
 subjects.

 `pg` tracks bare `Pid`s, so PubSub messages arrive as a raw process
 message rather than through a typed `Subject`. This function is the one
 place that knows how to recover a `Message(payload)` from that raw shape,
 so callers never need to build their own `select_record` matcher or reach
 for an unsafe coercion themselves.

 ```gleam
 let selector =
   process.new_selector()
   |> process.select(subject)
   |> pubsub.selecting(RemoteBroadcast)
 ```

```gleam
pub fn selecting(
  process.Selector(a),
  fn(Message(b)) -> a
) -> process.Selector(a)
```

### `start`

Start a PubSub instance

 This starts a pg scope. If the scope is already started (e.g., by another
 node or previous call), this is a no-op.

 `payload` is fixed by how the returned value is used (or annotated) at the
 call site — e.g. `pubsub.start(config) : PubSub(MySyncPayload)`.

```gleam
pub fn start(PubSubConfig) -> PubSub(a)
```

### `subscribe`

Subscribe the current process to a topic

 The calling process will receive `Message(payload)` values when
 broadcasts are sent to this topic. Add `selecting` to a `Selector` to
 receive them.

```gleam
pub fn subscribe(
  PubSub(a),
  String
) -> Nil
```

### `subscriber_count`

Get the number of subscribers for a topic (all nodes)

```gleam
pub fn subscriber_count(
  PubSub(a),
  String
) -> Int
```

### `subscribers`

Get all subscribers for a topic (all nodes)

```gleam
pub fn subscribers(
  PubSub(a),
  String
) -> List(process.Pid)
```

### `unsubscribe`

Unsubscribe the current process from a topic

```gleam
pub fn unsubscribe(
  PubSub(a),
  String
) -> Nil
```
