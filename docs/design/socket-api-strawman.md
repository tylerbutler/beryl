# Socket API strawman (ADR 0002)

Strawman for the app-side dispatch API proposed in
[ADR 0002](../adr/0002-app-side-dispatch.md). Nothing here compiles;
names and shapes are for discussion.

## Core types

```gleam
/// Everything the core delivers to the app's update function.
pub type Event(msg) {
  /// Client asked to join a topic. Must be answered with `AcceptJoin`
  /// or `RejectJoin` (see open question 1).
  Join(topic: String, payload: Dynamic, ref: Ref)
  /// Client message on a joined topic. `ref` is present for messages
  /// that expect a `phx_reply`.
  Message(topic: String, event: String, payload: Dynamic, ref: Option(Ref))
  /// Binary frame on a joined topic.
  Binary(topic: String, data: BitArray)
  /// A joined topic ended (client leave, kick, or socket close).
  /// Replaces the per-channel `terminate` callback.
  Closed(topic: String, reason: StopReason)
  /// Typed server-side message, sent via the socket's `Subject(msg)`.
  /// Replaces `send_info` — no erasure involved.
  Info(msg)
}

pub type Next(model, msg) {
  Next(model: model, effects: List(Effect))
  Stop(reason: StopReason)
}

/// One update may return several effects — unlike today's
/// `HandleResult`, which couples a single action to the socket value.
pub type Effect {
  AcceptJoin(ref: Ref, reply: Option(Json))
  RejectJoin(ref: Ref, reason: Json)
  ReplyOk(ref: Ref, payload: Json)
  ReplyError(ref: Ref, payload: Json)
  Push(topic: String, event: String, payload: Json)
  Broadcast(topic: String, event: String, payload: Json)
  PresenceTrack(topic: String, key: String, meta: Json)
  PresenceUntrack(topic: String, key: String)
  KickTopic(topic: String)
}
```

## Entry point

```gleam
pub fn start(
  config: Config,
  init: fn(ConnectInfo) -> #(model, List(Effect)),
  update: fn(model, Event(msg)) -> Next(model, msg),
) -> Sockets
```

`Sockets` is opaque and non-generic: `start` captures `model`/`msg` in
closures, so transports keep receiving an unparameterized handle through
the existing frame-level SPI. This is closure capture by a generic
function — plain Gleam, no identity FFI. Per-topic-pattern abuse config
(rate limits, join caps) moves into `Config` as data.

## Mapping from the current API

| Today (`beryl/channel`)          | Strawman                              |
| -------------------------------- | ------------------------------------- |
| `join` callback                  | `Join` event + `AcceptJoin`/`RejectJoin` |
| `JoinOk(reply, socket)`          | `Next(model, [AcceptJoin(ref, reply)])` |
| `handle_in` / `Reply` / `Push`   | `Message` event + `ReplyOk`/`Push`    |
| `handle_binary`                  | `Binary` event                        |
| `handle_info` (erased `Dynamic`) | `Info(msg)` event (typed)             |
| `terminate`                      | `Closed` event                        |
| `Stop(reason)`                   | `Stop(reason)`                        |
| assigns threading via `Socket`   | `model` threading via `Next`          |

## Single-channel app — no union, no router

```gleam
type Model { Model(user: String, joined: Bool) }
// msg = whatever the app sends itself; no wrapper needed.

fn update(model: Model, event: beryl.Event(Msg)) -> beryl.Next(Model, Msg) {
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

fn update(model: Model, event: beryl.Event(Msg)) -> beryl.Next(Model, Msg) {
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
`chat.update` and is embedded exactly as above — the Elm/Lustre
composition pattern.

## Open questions

1. **Join acknowledgment.** Explicit `AcceptJoin` effect (as drafted) vs
   inferring acceptance from `ReplyOk` on a join ref. Explicit is clearer;
   either way the core must reject `Push`/`Broadcast` to a topic whose
   join is unanswered, and define what happens if `update` never answers.
2. **Effect ordering.** Are effects applied in list order, and is a
   `Push` ordered after an `AcceptJoin` in the same list guaranteed to
   arrive after the join ack on the wire?
3. **Crash blast radius.** Today a crashing callback takes down state for
   the whole socket. One `update` per socket keeps that blast radius —
   confirm this matches current behavior rather than regressing it.
4. **Presence delivery.** Presence stays library-side (`Track`/`Untrack`
   effects; the core emits `presence_state`/`presence_diff` on the wire).
   Does the app ever need presence changes as `Event`s, or is wire-level
   sync enough (today it is)?
5. **Reply-outside-update.** Today `handle_info` can `Reply` only for it
   to be dropped without a client ref. The `ref`-carrying effects make
   this unrepresentable — verify no legitimate use is lost.
6. **Groups.** `group.send` to sockets sharing one app `msg` type is a
   typed send; confirm the group API needs no `Dynamic` anywhere.
