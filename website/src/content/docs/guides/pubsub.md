---
title: PubSub
description: Use typed pg-backed publish/subscribe directly, or attach it to Beryl for cluster-wide broadcasts.
---

Beryl's PubSub layer provides distributed publish/subscribe messaging on top of Erlang's `pg` module.

## Starting PubSub

```gleam
import beryl/pubsub

let ps = pubsub.start(pubsub.default_config())
let isolated = pubsub.start(pubsub.config_with_scope("my_app_pubsub"))
```

The scope becomes an Erlang atom, so it must be a **static, bounded deployment value** — never unbounded user input.

## Subscribing with `Subscriber(payload)`

Subscription is now explicit and typed:

```gleam
import beryl/pubsub

let sub = pubsub.subscriber(ps)
pubsub.join(sub, "room:lobby")
pubsub.join(sub, "room:alerts")

pubsub.leave(sub, "room:alerts")
```

A `Subscriber(payload)` belongs to the process that created it. Create it in the actor or test process that will receive the broadcasts.

## Receiving messages with `selecting`

`pubsub.selecting` folds the subscriber's typed subject into your own selector.

```gleam
import beryl/pubsub
import gleam/erlang/process

pub type Msg {
  Remote(pubsub.Message(String))
}

let ps = pubsub.start(pubsub.default_config())
let sub = pubsub.subscriber(ps)
pubsub.join(sub, "room:lobby")

let selector =
  process.new_selector()
  |> pubsub.selecting(sub, Remote)

case process.selector_receive(selector, 5000) {
  Ok(Remote(pubsub.Message(topic:, event:, payload:, from:))) ->
    handle_pubsub_message(topic, event, payload, from)
  Error(Nil) -> timeout()
}
```

This is the intended API. Do not match raw BEAM mailbox messages yourself.

## Message shape

```gleam
pub type Message(payload) {
  Message(topic: String, event: String, payload: payload, from: PubSubFrom)
}

pub type PubSubFrom {
  System
  FromPid(Pid)
  FromSocket(Pid, String)
}
```

`FromSocket` preserves an excluded socket id for cluster-wide "broadcast to everyone except this socket" behavior.

## Broadcasting

```gleam
import gleam/erlang/process
import gleam/json

pubsub.broadcast(ps, "room:lobby", "new_message", json.string("hello"))

pubsub.broadcast_from(
  ps,
  process.self(),
  "room:lobby",
  "new_message",
  json.string("hello"),
)

pubsub.broadcast_from_socket(
  ps,
  process.self(),
  socket_id,
  "room:lobby",
  "new_message",
  json.string("hello"),
)

pubsub.local_broadcast(ps, "room:lobby", "new_message", json.string("hello"))
```

Use `broadcast_from_socket` when you need cluster-wide "everyone except this socket" semantics. `beryl.broadcast_from` uses this internally.

## Querying subscribers

```gleam
let pids = pubsub.subscribers(ps, "room:lobby")
let count = pubsub.subscriber_count(ps, "room:lobby")
```

## Distributed operation

Because PubSub is built on `pg`, it automatically spans connected Erlang nodes. Joined process groups are shared across the cluster, and broadcasts reach subscribers on every node.

## Using PubSub with Beryl

Start PubSub separately, then attach it to the Beryl config you pass to `start` or `child_spec`.

```gleam
import beryl
import beryl/socket
import beryl/wire
import gleam/json

fn init(_info: socket.ConnectInfo(Nil)) -> #(Nil, List(socket.Effect)) {
  #(Nil, [])
}

fn update(model: Nil, _event: socket.Input(Nil)) -> socket.Next(Nil, Nil) {
  socket.Next(model, [])
}

let ps = pubsub.start(pubsub.default_config())
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_pubsub(ps)

let assert Ok(sockets) = beryl.start(config, init: init, update: update)

beryl.broadcast(sockets, "room:lobby", "notice", json.object([]))
```

When PubSub is configured, `beryl.broadcast`, `beryl.broadcast_from`, and `beryl.broadcast_presence_diff` distribute their work across the cluster automatically.

## Next steps

- [Presence](/guides/presence/) — presence replication is built on PubSub
- [Supervision](/guides/supervision/) — PubSub handles are application-owned, not part of the Beryl subtree
- [Architecture overview](/architecture/overview/) — where PubSub fits in the system
