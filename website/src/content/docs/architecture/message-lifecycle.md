---
title: Message Lifecycle
---

This page follows a message from the WebSocket connection to the client. Each
diagram shows one phase of beryl's message processing.

## Connect and init

When a client requests a WebSocket upgrade, Mist creates a unique socket ID. It
builds a `ConnectSeed` from the path, query, and headers. Mist then sends the
socket and its send functions to the runtime. The runtime calls your app's
`init` with `ConnectInfo`. This value contains the socket ID, seed, and typed
`Sender`. The runtime stores the model that `init` returns.

```mermaid
sequenceDiagram
  participant Client
  participant Mist as beryl_mist
  participant RT as runtime
  participant App as your init
  Client->>Mist: WebSocket upgrade
  Mist->>Mist: generate socket id, build ConnectSeed
  Mist->>RT: capture owner pid + admit_socket(...)
  RT->>App: init(ConnectInfo)
  App-->>RT: #(model, effects)
```

## Join a topic

A client sends a `phx_join` frame to join a topic. The connection process
decodes the frame. The runtime sends a `Join` event to your `update` function.
The function returns an `AcceptJoin` or `RejectJoin` effect.

```mermaid
sequenceDiagram
  participant Client
  participant Mist as beryl_mist
  participant Wire as wire/codec
  participant RT as runtime
  participant App as your update
  Client->>Mist: text frame [join_ref, ref, topic, "phx_join", payload]
  Mist->>Wire: decode_text
  Wire-->>RT: route_decoded(join)
  RT->>RT: validate topic (length, reserved names, rate, cap)
  RT->>App: update(model, Join(topic, payload, ref))
  App-->>RT: Next(model, [AcceptJoin(ref, reply)]) / [RejectJoin(ref, reason)]
  RT->>RT: subscribe socket to topic (on accept)
  RT-->>Client: phx_reply (ok/error)
```

The runtime rejects a `Join` that has no answer. Thus, beryl fails closed.

## Handle an inbound event

After a successful join, `update` receives each later topic frame as a
`Message` event. The effects list can send a reply, push, broadcast, or presence
write. An empty list sends nothing.

```mermaid
sequenceDiagram
  participant Client
  participant RT as runtime
  participant App as your update
  Client->>RT: text frame [.., topic, event, payload]
  RT->>App: update(model, Message(topic, event, payload, ref))
  App-->>RT: Next(model, effects)
  RT-->>Client: apply effects in order (ReplyOk, Push, ...)
```

## Broadcast fan-out

A broadcast sends a message to each socket on a topic. `Broadcast` and
`beryl.broadcast` include the source socket. `BroadcastFrom` and
`beryl.broadcast_from` exclude it. When you configure PubSub, Erlang `pg` sends
the broadcast to other runtime nodes. Each runtime then sends it to local
subscribers.

```mermaid
sequenceDiagram
  participant Origin as origin update/app
  participant RT as runtime
  participant PS as pubsub (pg)
  participant Subs as subscriber sockets
  Origin->>RT: Broadcast(topic, event, payload)
  RT-->>Subs: push via each subscriber's send fn
  RT->>PS: broadcast_from (cluster fan-out)
  PS-->>RT: deliver to each remote runtime
```

## Heartbeat and eviction

Clients send a `heartbeat` frame on the `"phoenix"` topic at set intervals. The
runtime replies and records the time. A timer removes sockets that miss the
configured deadline. The app does not receive heartbeat frames.

```mermaid
sequenceDiagram
  participant Client
  participant RT as runtime
  Client->>RT: [.., "phoenix", "heartbeat", {}]
  RT-->>Client: heartbeat_reply
  Note over RT: periodic timer checks last-seen
  RT->>RT: evict sockets past deadline (Closed(HeartbeatTimeout) to app)
```

## Disconnect and close

When a client closes the WebSocket, Mist notifies the runtime. The runtime sends
`Closed(topic, reason)` to `update` for each joined topic. It then removes the
subscriptions and socket state.

```mermaid
sequenceDiagram
  participant Client
  participant Mist as beryl_mist
  participant RT as runtime
  participant App as your update
  Client->>Mist: socket close
  Mist->>RT: socket_disconnected(id)
  RT->>App: update(model, Closed(topic, reason)) per joined topic
  RT->>RT: unsubscribe topics, drop socket state
```

The same `Closed` path is used for client leaves, heartbeat timeouts,
`KickTopic`, and graceful `beryl.stop` shutdown.

## Where the channel layer fits

`beryl/channel` supplies the `init` and `update` pair in these diagrams. Its
`init` builds one router for each socket. Its `update` maps each input to the
live channel instance for that topic.

| Runtime input | Router behavior |
|---|---|
| `Join(topic, payload, ref)` | First matching handler wins; its join result emits `AcceptJoin` followed by ordered join actions, or `RejectJoin`. No match is refused with `{"reason": "unmatched topic"}` |
| `Message(topic, ..)` / `Binary(topic, ..)` | Delivered to the live instance for that topic |
| `Info(envelope)` | Topic and join generation are checked before the sealed typed value is opened; stale mail is dropped |
| `Closed(topic, reason)` | Calls `on_terminate` and lowers its actions after the topic is already unsubscribed |

Termination has one edge case. The router removes the instance in the model
returned by the `Closed` turn. If `on_terminate` panics, the core discards that
model and keeps the old model. The retained instance can receive its own
generation-scoped `channel.notify` mail. Client messages cannot reach the
closed topic. A rejoin replaces the instance, and socket shutdown removes it.
See
[Crash behavior](/guides/channels/#crash-behavior).

Each channel action maps to one core effect. The runtime preserves their order.
An asynchronous presence effect can pause one socket while other sockets
continue.

## Concurrency note

One OTP actor processes the runtime mailbox in sequence. Broadcasts arrive as
messages. Tests must select the exact message shape and drain queued messages.

## Where this lives

- `packages/beryl_mist/src/beryl_mist.gleam`: connect/close, edge decoding, frame routing
- `src/beryl/runtime.gleam`: event dispatch, effect application, heartbeat timer
- `src/beryl/wire.gleam`, `src/beryl/wire/codec.gleam`: decode/encode frames
- `src/beryl/pubsub.gleam`: fan-out
