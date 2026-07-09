---
title: beryl/pubsub
description: PubSub - Distributed publish/subscribe using Erlang pg
---

PubSub - Distributed publish/subscribe using Erlang pg

 Provides topic-based pub/sub messaging backed by Erlang's built-in `pg`
 module. Subscribers are tracked by process group, so messages are delivered
 to all nodes in the cluster automatically.

 ## Quick Start

 ```gleam
 let ps = pubsub.start(pubsub.default_config())
 pubsub.subscribe(ps, "room:lobby")
 pubsub.broadcast(ps, "room:lobby", "new_msg", json.string("hello"))
 ```

## Types

### `Message`

A PubSub message delivered to subscribers.

 This type is intentionally transparent so subscribers can inspect the topic,
 event, payload, and sender metadata delivered to their process mailbox.

 ## Frozen wire contract

 `Message` is sent **raw between nodes** via `pg`, so its runtime shape —
 the record tag and its four fields, in this order — is a frozen v1 wire
 contract, not just a source-level API. It will not change within 1.x:
 subscribers select it as a 4-field `message` record, and a rolling
 cluster upgrade must never mis-parse a frame from an older node. If the
 envelope ever needs new fields, they will arrive as a **new record tag**
 (a new variant), which old nodes' selectors simply do not match — never
 as a change to this record. The same applies to `PubSubFrom`.

```gleam
pub type Message {
  Message(
    topic: String,
    event: String,
    payload: json.Json,
    from: PubSubFrom
  )
}
```

### `PubSub`

A running PubSub instance.

 This handle is intentionally opaque so callers cannot forge pg scopes or
 depend on the runtime representation.

```gleam
pub type PubSub
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

 Part of the frozen v1 wire contract described on `Message`.

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
  PubSub,
  String,
  String,
  json.Json
) -> Nil
```

### `broadcast_from`

Broadcast a message to all subscribers except those from a specific pid

```gleam
pub fn broadcast_from(
  PubSub,
  process.Pid,
  String,
  String,
  json.Json
) -> Nil
```

### `broadcast_from_socket`

Broadcast a message to all subscribers except a process, preserving a socket
 ID that receiving channel coordinators should exclude locally.

```gleam
pub fn broadcast_from_socket(
  PubSub,
  process.Pid,
  String,
  String,
  String,
  json.Json
) -> Nil
```

### `config_with_scope`

Create a PubSub configuration with a custom scope name

 The scope name is converted to an Erlang atom via `binary_to_atom`.
 Atoms are never garbage-collected, so the scope name must be a static,
 bounded value — never derive it from user input, or a malicious or
 high-cardinality source could exhaust the atom table and crash the VM.

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
  PubSub,
  String,
  String,
  json.Json
) -> Nil
```

### `start`

Start a PubSub instance

 This starts a pg scope. If the scope is already started (e.g., by another
 node or previous call), this is a no-op.

```gleam
pub fn start(PubSubConfig) -> PubSub
```

### `subscribe`

Subscribe the current process to a topic

 The calling process will receive `Message` values when broadcasts
 are sent to this topic.

```gleam
pub fn subscribe(
  PubSub,
  String
) -> Nil
```

### `subscriber_count`

Get the number of subscribers for a topic (all nodes)

```gleam
pub fn subscriber_count(
  PubSub,
  String
) -> Int
```

### `subscribers`

Get all subscribers for a topic (all nodes)

```gleam
pub fn subscribers(
  PubSub,
  String
) -> List(process.Pid)
```

### `unsubscribe`

Unsubscribe the current process from a topic

```gleam
pub fn unsubscribe(
  PubSub,
  String
) -> Nil
```
