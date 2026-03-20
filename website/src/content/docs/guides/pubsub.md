---
title: PubSub
---

beryl's PubSub layer provides distributed publish/subscribe messaging built on Erlang's `pg` (process groups) module.

## Starting PubSub

```gleam
import beryl/pubsub

// Default scope ("beryl_pubsub")
let assert Ok(ps) = pubsub.start(pubsub.default_config())

// Custom scope (isolates process groups)
let assert Ok(ps) = pubsub.start(pubsub.config_with_scope("my_app_pubsub"))
```

The scope maps to a `pg` scope atom. Different scopes are completely isolated from each other.

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
  System              // Broadcast with no sender
  FromPid(Pid)        // Broadcast from a specific process
}
```

## Broadcasting

```gleam
import gleam/json

// Broadcast to all subscribers (all nodes)
pubsub.broadcast(ps, "room:lobby", "new_message", json.string("hello"))

// Broadcast to all except the sender
pubsub.broadcast_from(
  ps,
  process.self(),
  "room:lobby",
  "new_message",
  json.string("hello"),
)

// Broadcast to local node only
pubsub.local_broadcast(ps, "room:lobby", "new_message", json.string("hello"))
```

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

let assert Ok(ps) = pubsub.start(pubsub.default_config())
let config = beryl.default_config() |> beryl.with_pubsub(ps)
let assert Ok(channels) = beryl.start(config)

// beryl.broadcast() now sends to all nodes automatically
beryl.broadcast(channels, "room:lobby", "event", payload)
```
