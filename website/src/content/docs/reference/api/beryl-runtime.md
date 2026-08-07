---
title: beryl/runtime
description: Runtime actor for app-side dispatch systems started with `beryl.start_app`.
---

Runtime actor for app-side dispatch systems started with `beryl.start_app`.

 One runtime actor serves every socket started through
 `beryl.start_app`. It is generic over the app's `model` and `msg`
 types: per-socket models live in the actor state, typed `Info`
 messages arrive through the actor's own mailbox, and no value is ever
 type-erased. Transports reach the runtime through monomorphic closures
 captured by `beryl.start_app`, so the frame-level transport SPI stays
 unparameterized.

 The runtime owns everything the coordinator owns under the
 channel-module API — inbound decoding and validation, rate limiting,
 heartbeat eviction, topic subscriptions, broadcast fan-out — and adds
 the effect interpreter: each `update` returns a list of `Effect`s that
 are applied strictly in order within a single actor turn, so effect
 list order is wire order.

## Types

### `Config`

Configuration for the runtime actor. Built by `beryl.start_app` from a
 `beryl.Config`; the fields mirror the coordinator's configuration plus
 per-topic-pattern rate limits and the optional presence handle used by
 the presence effects.

```gleam
pub type Config {
  Config(
    codec: codec.Codec,
    heartbeat_check_interval_ms: Int,
    heartbeat_timeout_ms: Int,
    message_limits: option.Option(rate_limit.RateLimitConfig),
    join_limits: option.Option(rate_limit.RateLimitConfig),
    channel_limits: option.Option(rate_limit.RateLimitConfig),
    channel_limiter_max_keys_per_socket: Int,
    topic_rates: List(#(topic.TopicPattern, rate_limit.RateLimitConfig)),
    max_topic_length: Int,
    max_event_length: Int,
    max_joined_topics_per_socket: Int,
    logging: internal.LoggingConfig,
    presence: option.Option(presence.Presence)
  )
}
```

### `Msg`

Messages the runtime actor handles.

```gleam
pub type Msg(a) {
  SocketConnected(
    socket_id: String,
    send: fn(String) -> Result(Nil, Nil),
    send_binary: fn(BitArray) -> Result(Nil, Nil),
    codec: option.Option(codec.Codec),
    seed: event.ConnectSeed
  )
  SocketDisconnected(socket_id: String)
  RegisterCloser(
    socket_id: String,
    close: fn() -> Nil
  )
  RouteText(
    socket_id: String,
    raw_text: String
  )
  RouteDecoded(
    socket_id: String,
    msg: codec.Inbound
  )
  HandleBinary(
    socket_id: String,
    data: BitArray
  )
  AppInfo(
    socket_id: String,
    message: a
  )
  Broadcast(
    topic: String,
    event: String,
    payload: json.Json,
    except: option.Option(String)
  )
  RemoteBroadcast(pubsub.Message(json.Json))
  CheckHeartbeats
  Stop(reply: process.Subject(Nil))
}
```

#### Constructors

##### `AppInfo(
  socket_id: String,
  message: a
)`

A typed server-side message for one socket, sent through its
 `Sender`. Delivered to `update` as `Info(message)`.

##### `Broadcast(
  topic: String,
  event: String,
  payload: json.Json,
  except: option.Option(String)
)`

Local broadcast fan-out. PubSub forwarding is the sender's concern
 (the `beryl` broadcast helpers and the effect interpreter forward
 before/while sending this).

### `StartError`

Errors when starting the runtime.

```gleam
pub type StartError {
  InvalidHeartbeatTimeout
  ActorStartFailed(actor.StartError)
}
```

## Functions

### `start_named`

Start the runtime actor registered under `name`.

 There is deliberately no unsupervised start: `beryl.start_app` runs
 the runtime under a supervisor, and a crash restarts it with dispatch
 intact because the `init`/`update` closures live in the child
 specification. The registered name keeps transport and broadcast
 handles valid across restarts (per-socket state is dropped, matching
 coordinator restart semantics).

```gleam
pub fn start_named(
  Config,
  name: process.Name(Msg(a)),
  pubsub: option.Option(pubsub.PubSub(json.Json)),
  init: fn(event.ConnectInfo(a)) -> #(b, List(event.Effect)),
  update: fn(b, event.Event(a)) -> event.Next(b, a)
) -> Result(actor.Started(process.Subject(Msg(a))), StartError)
```
