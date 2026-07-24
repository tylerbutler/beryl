# Socket API reference (ADR 0002)

Final API and design record for the app-side dispatch model accepted in
[ADR 0002](../adr/0002-app-side-dispatch.md). This document reflects the
shipped `beryl`/`beryl/socket` API — see `beryl.gleam` and `beryl/socket.gleam`
for the authoritative signatures and doc comments, and the
[generated API reference](/reference/api/) for the full public surface.

## Core types

```gleam
/// Everything the runtime delivers to the app's `update` function.
pub type Input(msg) {
  /// A client asked to join a topic. Answer with `AcceptJoin` or
  /// `RejectJoin`; a `Join` left unanswered by the end of the update turn
  /// is rejected automatically (fail closed).
  Join(topic: String, payload: Dynamic, ref: Ref)
  /// A client message on a joined topic. `ref` is present for messages
  /// that expect a reply.
  Message(topic: String, event: String, payload: Dynamic, ref: Option(Ref))
  /// A binary frame on a joined topic.
  Binary(topic: String, data: BitArray)
  /// A joined topic ended (client leave, kick, crash, or socket close).
  /// Delivered on every exit path.
  Closed(topic: String, reason: StopReason)
  /// A typed server-side message, sent via the socket's `Sender(msg)`
  /// (see `ConnectInfo.self` and `socket.notify`). An ordinary typed send —
  /// no erasure involved.
  Info(msg)
}

/// The result of one `update` call.
pub type Next(model, msg) {
  /// Continue with the given model, applying the effects in order.
  Next(model: model, effects: List(Effect))
  /// Tear down the socket: every joined topic receives a `Closed` event
  /// and the transport connection is closed.
  Stop(reason: StopReason)
}

/// One update may return several effects, applied strictly in list order
/// inside a single runtime actor turn — list order is wire order.
pub type Effect {
  AcceptJoin(ref: Ref, reply: Option(Json))
  RejectJoin(ref: Ref, reason: Json)
  ReplyOk(ref: Ref, payload: Json)
  ReplyError(ref: Ref, payload: Json)
  Push(topic: String, event: String, payload: Json)
  Broadcast(topic: String, event: String, payload: Json)
  BroadcastFrom(topic: String, event: String, payload: Json)
  PresenceTrack(topic: String, key: String, meta: Json)
  PresenceUntrack(topic: String, key: String)
  PushPresence(topic: String, event: String, encode: fn(List(PresenceEntry)) -> Json)
  BroadcastPresence(topic: String, event: String, encode: fn(List(PresenceEntry)) -> Json)
  KickTopic(topic: String)
}
```

`Ref` is opaque and single-use per pending join/message; it is scoped to the
topic it was issued for, so it can be stored in the model and used from a
later `update` turn (for example, replying once an async lookup completes).

## Entry points

```gleam
pub fn start(
  config: Config,
  init init: fn(ConnectInfo(msg)) -> #(model, List(Effect)),
  update update: fn(model, Input(msg)) -> Next(model, msg),
) -> Result(Sockets, StartError)

pub fn child_spec(
  config: Config,
  init init: fn(ConnectInfo(msg)) -> #(model, List(Effect)),
  update update: fn(model, Input(msg)) -> Next(model, msg),
) -> Result(
  #(Sockets, ChildSpecification(static_supervisor.Supervisor)),
  ConfigError,
)
```

`Sockets` is opaque and non-generic: `start`/`child_spec` capture
`model`/`msg` in closures, so transports keep receiving an unparameterized
handle through the frame-level `beryl/transport` SPI — closure capture by a
generic function, plain Gleam, no identity FFI. Per-topic-pattern abuse
config (rate limits, join caps) lives on `Config`, built with
`beryl.config` and its `with_*` builders.

`start` owns a standalone, detached Beryl subtree (runtime plus an optional
connection limiter) and returns a ready-to-use `Sockets`. `child_spec`
validates the same `Config` and returns a name-backed `Sockets` plus a
`ChildSpecification` to embed in the caller's own supervision tree; the
handle works immediately, even before the tree that owns it is started. See
[Supervision](/guides/supervision/) for the full standalone-vs-embedded
contract, what happens to a joined socket's model on an unsupervised
runtime crash, and what `stop` does and does not tear down.

## Mapping from the deleted channel-module API

The old API mirrored Phoenix Channels, so the website's
[Coming from Phoenix](/guides/coming-from-phoenix/) guide gives the same
mapping in user-facing form, with side-by-side code and the Phoenix-specific
concepts (assigns, `socket_ref`, Presence, `Endpoint.broadcast`).

| Old (`beryl/channel`, deleted)   | App-side dispatch                        |
| --------------------------------- | ----------------------------------------- |
| `join` callback                  | `Join` event + `AcceptJoin`/`RejectJoin`  |
| `JoinOk(reply, socket)`          | `Next(model, [AcceptJoin(ref, reply)])`   |
| `handle_in` / `Reply` / `Push`   | `Message` event + `ReplyOk`/`Push`        |
| `handle_binary`                  | `Binary` event                            |
| `handle_info` (erased `Dynamic`) | `Info(msg)` event (typed)                 |
| `terminate`                      | `Closed` event                            |
| `Stop(reason)`                   | `Stop(reason)`                            |
| assigns threading via `Socket`   | `model` threading via `Next`              |
| `beryl.register(handler)`        | routing inside the app's `update`         |
| `beryl.start(config)` + registry | `beryl.start(config, init:, update:)`     |
| `send_info(socket, msg)`         | `socket.notify(sender, msg)`               |

## Single-channel app — no union, no router

```gleam
type Model { Model(user: String, joined: Bool) }
// msg = whatever the app sends itself; no wrapper needed.

fn update(model: Model, event: beryl.Input(Msg)) -> beryl.Next(Model, Msg) {
  case event {
    beryl.Join("room:" <> _, _payload, ref) ->
      beryl.Next(Model(..model, joined: True), [beryl.AcceptJoin(ref, None)])
    beryl.Message(topic, "new_msg", payload, _ref) ->
      beryl.Next(model, [beryl.Broadcast(topic, "new_msg", relay(payload))])
    _ -> beryl.Next(model, [])
  }
}
```

## Multi-channel app — union and router

```gleam
type Model { Model(chats: Dict(String, chat.Model), admin: admin.Model) }
type Msg  { ChatMsg(topic: String, msg: chat.Msg)  AdminMsg(admin.Msg) }

fn update(model: Model, event: beryl.Input(Msg)) -> beryl.Next(Model, Msg) {
  case event {
    beryl.Join("chat:" <> id, payload, ref) ->
      // delegate to chat.join, store its model in the dict
      ...
    beryl.Join("admin", payload, ref) -> ...
    beryl.Info(ChatMsg(topic, msg)) ->
      // total match: every variant here is reachable
      ...
    ...
  }
}
```

Third-party functionality ships as `chat.Model` / `chat.Msg` /
`chat.update` and is embedded exactly as above — the Elm/Lustre composition
pattern.

## Resolved design questions

These were open questions during the ADR 0002 proposal; each is settled in
the shipped API:

1. **Join acknowledgment.** Explicit `AcceptJoin`/`RejectJoin` effects, not
   inferred from `ReplyOk`. The runtime rejects `Push`/`Broadcast` to a
   topic whose join is unanswered, and a `Join` left unanswered by the end
   of the `update` turn is rejected automatically (fail closed).
2. **Effect ordering.** Effects are applied strictly in list order, inside
   a single runtime actor turn, and every frame for a socket is written by
   that one actor — so list order is wire order. A `Push` ordered after an
   `AcceptJoin` in the same list is guaranteed to arrive after the join ack.
3. **Crash blast radius.** One `update` per socket keeps the blast radius
   at the socket: a crashing `update` takes down that socket's model and
   all its joined topics, matching prior channel-module behavior, and does
   not affect other sockets.
4. **Presence delivery.** Presence stays runtime-side: `PresenceTrack`/
   `PresenceUntrack` effects update the CRDT and broadcast
   `presence_diff`; `PushPresence`/`BroadcastPresence` read presence state
   at apply time (after earlier `PresenceTrack`/`PresenceUntrack` effects
   in the same list) rather than as inputs the app must react to.
5. **Reply-outside-update.** `Ref` is an ordinary value that can be stored
   in the model and used from a later `update` turn (e.g. replying from an
   `Info` event once an async lookup completes), so no legitimate
   reply-later use is lost.
6. **Groups.** `beryl/group` sends to sockets sharing one app `msg` type
   through the socket's typed `Sender(msg)` — a typed send, no `Dynamic`
   anywhere in the public group API.
