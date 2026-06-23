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
 let assert Ok(ps) = pubsub.start(pubsub.default_config())
 pubsub.subscribe(ps, "room:lobby")
 pubsub.broadcast(ps, "room:lobby", "new_msg", json.string("hello"))
 ```

## Types

### `Message`

A PubSub message delivered to subscribers

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

A running PubSub instance

```gleam
pub type PubSub {
  PubSub(scope: dynamic.Dynamic)
}
```

### `PubSubConfig`

PubSub configuration

```gleam
pub type PubSubConfig {
  PubSubConfig(scope: dynamic.Dynamic)
}
```

### `PubSubFrom`

Identifies the sender of a broadcast

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

### `StartError`

Errors when starting PubSub

```gleam
pub type StartError {
  PgStartFailed
}
```

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
pub fn start(PubSubConfig) -> Result(PubSub, StartError)
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
