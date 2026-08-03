---
title: beryl_channels/channel
description: The channel composition surface: a channel is a topic pattern paired
---

The channel composition surface: a channel is a topic pattern paired
 with a typed `join` callback, and a joined channel is a record of
 closures over that channel's own private state.

 ## Shape

 ```gleam
 import beryl_channels/channel
 import gleam/json

 pub type Note {
   Announce(String)
 }

 pub fn room() -> channel.Handler {
   channel.handler("room:*", fn(info, topic, _payload) {
     let callbacks =
       channel.callbacks()
       |> channel.on_message(fn(count, message) {
         channel.continue_with(
           count + 1,
           channel.actions()
             |> channel.broadcast(message.event, json.int(count + 1)),
         )
       })
       |> channel.on_info(fn(count, note) {
         let Announce(text) = note
         channel.continue_with(
           count,
           channel.actions() |> channel.push("announce", json.string(text)),
         )
       })
       |> channel.on_terminate(fn(_count, _reason) {
         channel.actions()
         |> channel.broadcast("left", json.string(topic))
       })

     channel.notify(info.self, Announce("later, on this topic"))
     channel.accept(channel.joined(0, callbacks))
     |> channel.with_actions(
       channel.actions() |> channel.push("welcome", json.string(topic)),
     )
   })
 }
 ```

 ## Type safety

 A channel picks two types of its own: `state`, its private model, and
 `info`, the type of server-side messages it accepts. Neither escapes:
 [`joined`](#joined) seals `state` inside the callback closures, and
 [`handler`](#handler) seals `info` inside the registration closure, so
 the resulting [`Handler`](#Handler) is not generic and handlers with
 unrelated `state` and `info` types compose in one list. No value is
 ever erased to `Dynamic` and no unchecked coercion is involved:
 typed `info` values travel inside a closure that only the join which
 created it can open, and the socket that owns the join opens it — or
 drops it unopened, if the join has since ended.

 ## Ordering

 [`Actions`](#Actions) are applied strictly in the order they were
 added, and they always target the channel's own topic. They lower onto
 beryl's core `Effect` values, which the runtime applies in list order
 inside a single actor turn — so action order is wire order.

 A join's actions (see [`with_actions`](#with_actions)) are lowered in
 the same turn as the join acknowledgment, immediately after it: the
 socket is already subscribed, so a push cannot precede its own join
 reply and a presence check and its `presence_track` cannot be
 interleaved with another turn.

 [`on_terminate`](#on_terminate) actions are lowered in the turn that
 closes the topic, after the channel instance is gone. The topic is
 already unsubscribed by then, so core **drops pushes** (and presence
 snapshots pushed to this socket) on it; broadcasts, presence tracking,
 and untracking still take effect and still reach the topic's remaining
 subscribers.

## Types

### `Actions`

An ordered list of things to do on the channel's own topic.

 Build one with [`actions`](#actions) and the builder functions below;
 they are applied in the order they were added. Actions are always
 scoped to the current channel's topic, so no action names a topic.

```gleam
pub type Actions
```

### `Callbacks`

The typed callbacks of one channel, over its private `state` and its
 server-side message type `info`.

 Start from [`callbacks`](#callbacks) — which ignores every input and
 stays joined — and override only what the channel cares about. Seal the
 result with [`joined`](#joined).

```gleam
pub type Callbacks(a, b)
```

### `Handler`

A registered channel: a topic pattern plus its sealed `join` callback.

 `Handler` is deliberately not generic. A channel's `state` and `info`
 types are sealed inside the closure captured here, so a single
 `List(Handler)` can hold channels that agree on nothing.

```gleam
pub type Handler
```

### `JoinedChannel`

A live channel instance: `state` bound to `callbacks`.

 The `state` type is sealed inside the closures this builds, so joined
 channels with unrelated private states share one type.

```gleam
pub type JoinedChannel(a)
```

### `JoinInfo`

Everything a `join` callback learns about the connection it is joining.

 `socket_id` and `seed` come straight from the transport's connect
 information; `self` is this channel's own generation-scoped
 [`Sender`](#Sender), for scheduling a *later* turn — including from
 another process. Work that has to be part of the join itself belongs
 in [`with_actions`](#with_actions) instead.

```gleam
pub type JoinInfo(a) {
  JoinInfo(
    socket_id: String,
    seed: socket.ConnectSeed,
    self: Sender(a)
  )
}
```

### `JoinResult`

A `join` callback's answer: join this channel, or refuse.

```gleam
pub type JoinResult(a)
```

### `Message`

A client message delivered to a joined channel's `on_message` callback.

 `reply` is present only when the client asked for a reply; pass it to
 [`reply_ok`](#reply_ok) or [`reply_error`](#reply_error).

```gleam
pub type Message {
  Message(
    topic: String,
    event: String,
    payload: dynamic.Dynamic,
    reply: option.Option(socket.Ref)
  )
}
```

### `Next`

What a channel callback decided to do next.

 Build one with [`continue`](#continue), [`continue_with`](#continue_with),
 [`close`](#close), [`close_with`](#close_with), or
 [`stop_socket`](#stop_socket).

```gleam
pub type Next(a)
```

### `Sender`

A typed handle for sending server-side messages to one joined channel.

 Obtained from [`JoinInfo`](#JoinInfo) in the `join` callback and safe to
 share with any process. Messages sent through it are delivered to the
 channel's `on_info` callback with their type intact.

 A sender is scoped to the join that produced it. Sending is
 asynchronous and never fails, so it cannot report that the channel is
 gone: liveness is decided where the message is delivered. If the
 channel has closed, or the same topic has since been joined again, the
 message is dropped there — it is never handed to a different join.

```gleam
pub type Sender(a)
```

## Functions

### `accept`

Accept the join with an empty acknowledgment.

```gleam
pub fn accept(JoinedChannel(a)) -> JoinResult(a)
```

### `accept_with`

Accept the join, returning `reply` in the join acknowledgment.

```gleam
pub fn accept_with(
  JoinedChannel(a),
  json.Json
) -> JoinResult(a)
```

### `actions`

An empty action list.

```gleam
pub fn actions() -> Actions
```

### `broadcast`

Broadcast to every subscriber of this channel's topic, including this
 socket.

```gleam
pub fn broadcast(
  Actions,
  String,
  json.Json
) -> Actions
```

### `broadcast_from`

Broadcast to every subscriber of this channel's topic except this
 socket.

```gleam
pub fn broadcast_from(
  Actions,
  String,
  json.Json
) -> Actions
```

### `broadcast_presence`

Broadcast a presence snapshot for this channel's topic to every
 subscriber, with the same apply-time `encode` semantics as
 [`push_presence`](#push_presence).

```gleam
pub fn broadcast_presence(
  Actions,
  String,
  fn(List(presence.PresenceEntry)) -> json.Json
) -> Actions
```

### `callbacks`

Callbacks that ignore every input and keep the channel joined.

```gleam
pub fn callbacks() -> Callbacks(a, b)
```

### `close`

Leave this channel. The socket stays connected and its other channels
 are untouched; this channel's `on_terminate` callback still runs.

```gleam
pub fn close() -> Next(a)
```

### `close_with`

Leave this channel after applying `actions` in order.

```gleam
pub fn close_with(Actions) -> Next(a)
```

### `continue`

Stay joined with the given state and no actions.

```gleam
pub fn continue(a) -> Next(a)
```

### `continue_with`

Stay joined with the given state, applying `actions` in order.

```gleam
pub fn continue_with(
  a,
  Actions
) -> Next(a)
```

### `handler`

Register a channel for every topic matching `pattern`.

 `pattern` uses beryl's topic pattern syntax (`"room:lobby"`,
 `"room:*"`, `"document:*:ops"`, `"*"`) and is validated when the
 handler table is used; see `beryl_channels.validate_handlers`.

 `join` receives the connection's [`JoinInfo`](#JoinInfo), the concrete
 topic that matched, and the client's join payload, and answers with
 [`accept`](#accept), [`accept_with`](#accept_with), or
 [`reject`](#reject).

```gleam
pub fn handler(
  String,
  fn(JoinInfo(a), String, dynamic.Dynamic) -> JoinResult(a)
) -> Handler
```

### `joined`

Bind a channel's initial private state to its callbacks.

 This is where `state` disappears from the type: every callback is
 wrapped in a closure that captures the current state, and each
 [`continue`](#continue) result rebuilds the same closures over the next
 state. No state value is ever erased or coerced.

```gleam
pub fn joined(
  a,
  Callbacks(a, b)
) -> JoinedChannel(b)
```

### `notify`

Send a typed server-side message to the channel that owns `sender`.

 Each call enqueues exactly one message, and each enqueued message
 produces exactly one `on_info` call — sends are never coalesced, and
 they are delivered in the order the owning socket receives them.

 This is a fire-and-forget send: it returns as soon as the message is
 enqueued, whether or not the channel is still joined. A message
 enqueued for a channel that has already ended is discarded on arrival
 (see [`Sender`](#Sender)).

```gleam
pub fn notify(
  Sender(a),
  a
) -> Nil
```

### `on_binary`

Handle binary frames on this channel's topic.

```gleam
pub fn on_binary(
  Callbacks(a, b),
  fn(a, BitArray) -> Next(a)
) -> Callbacks(a, b)
```

### `on_info`

Handle typed server-side messages sent through this channel's
 [`Sender`](#Sender).

```gleam
pub fn on_info(
  Callbacks(a, b),
  fn(a, b) -> Next(a)
) -> Callbacks(a, b)
```

### `on_message`

Handle client messages on this channel's topic.

```gleam
pub fn on_message(
  Callbacks(a, b),
  fn(a, Message) -> Next(a)
) -> Callbacks(a, b)
```

### `on_terminate`

Run cleanup when the channel ends, for any reason: client leave, a
 [`close`](#close) result, a socket teardown, or a disconnect.

 The returned [`Actions`](#Actions) are applied in the turn that closes
 this topic, right after the channel instance is gone — which is why a
 leave announcement or a post-leave presence roster belongs here rather
 than in an out-of-band broadcast.

 The topic is already unsubscribed at that point, so core drops
 [`push`](#push) and [`push_presence`](#push_presence) actions on it
 (they would have nowhere to land) while
 [`broadcast`](#broadcast), [`broadcast_from`](#broadcast_from),
 [`broadcast_presence`](#broadcast_presence),
 [`presence_track`](#presence_track), and
 [`presence_untrack`](#presence_untrack) still take effect and still
 reach the topic's remaining subscribers.

```gleam
pub fn on_terminate(
  Callbacks(a, b),
  fn(a, socket.StopReason) -> Actions
) -> Callbacks(a, b)
```

### `pattern`

The topic pattern a handler was registered with.

```gleam
pub fn pattern(Handler) -> String
```

### `presence_track`

Track this socket's presence under `key` on this channel's topic and
 broadcast the matching `presence_diff` join.

 Requires a presence handle on the `Config` (`beryl.with_presence_handle`).

```gleam
pub fn presence_track(
  Actions,
  String,
  json.Json
) -> Actions
```

### `presence_untrack`

Untrack a presence previously tracked with
 [`presence_track`](#presence_track) and broadcast the matching
 `presence_diff` leave.

```gleam
pub fn presence_untrack(
  Actions,
  String
) -> Actions
```

### `push`

Push a server-initiated message to this socket on this channel's topic.

```gleam
pub fn push(
  Actions,
  String,
  json.Json
) -> Actions
```

### `push_presence`

Push a presence snapshot for this channel's topic to this socket.

 `encode` runs when the action is applied, so it already sees any
 earlier [`presence_track`](#presence_track) or
 [`presence_untrack`](#presence_untrack) in the same list.

```gleam
pub fn push_presence(
  Actions,
  String,
  fn(List(presence.PresenceEntry)) -> json.Json
) -> Actions
```

### `reject`

Refuse the join, returning `reason` to the client.

```gleam
pub fn reject(json.Json) -> JoinResult(a)
```

### `reply_error`

Reply with an error to a client message, using the `reply` handle from
 the [`Message`](#Message) that asked for it.

```gleam
pub fn reply_error(
  Actions,
  socket.Ref,
  json.Json
) -> Actions
```

### `reply_ok`

Reply successfully to a client message, using the `reply` handle from
 the [`Message`](#Message) that asked for it.

```gleam
pub fn reply_ok(
  Actions,
  socket.Ref,
  json.Json
) -> Actions
```

### `stop_socket`

Tear down the whole socket, not just this channel.

 This deliberately carries no actions: the socket and every channel on
 it are going away, so there is nothing left to apply them to.

```gleam
pub fn stop_socket(socket.StopReason) -> Next(a)
```

### `with_actions`

Add ordered actions to run as part of accepting this join.

 They are applied in the same update turn as the acknowledgment and
 strictly after it, so the socket is already subscribed to the topic:
 a [`push`](#push) here cannot overtake its own join reply, and a
 presence check made in the `join` callback and the
 [`presence_track`](#presence_track) that acts on it cannot be split by
 another turn.

 This is what to reach for instead of notifying yourself from `join`:
 [`notify`](#notify) schedules a *later* turn, which is right for work
 that may block or wait, but it cannot be atomic with the join.

 Actions already attached stay ahead of the ones added here. A refused
 join has no topic to act on, so this returns [`reject`](#reject)
 results unchanged.

```gleam
pub fn with_actions(
  JoinResult(a),
  Actions
) -> JoinResult(a)
```
