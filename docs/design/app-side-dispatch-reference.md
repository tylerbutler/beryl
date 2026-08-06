# Socket API reference (ADR 0002)

Final API and design record for the app-side dispatch model accepted in
[ADR 0002](../adr/0002-app-side-dispatch.md). This document reflects the
shipped `beryl`/`beryl/event` API — see `beryl.gleam` and `beryl/event.gleam`
for the authoritative signatures and doc comments, and the
[generated API reference](/reference/api/) for the full public surface.

## Core types

```gleam
/// Everything the runtime delivers to the app's `update` function.
pub type Event(msg) {
  /// A client asked to join a topic. Answer with `AcceptJoin` or
  /// `RejectJoin`; a `Join` left unanswered by the end of the update turn
  /// is rejected automatically (fail closed).
  Join(topic: String, payload: Dynamic, ref: Ref)
  /// A client message on a joined topic. `ref` is present for messages
  /// that expect a reply.
  Message(topic: String, event: String, payload: Dynamic, ref: Option(Ref))
  /// An undecoded binary frame on a joined topic (only for codecs without
  /// a binary decoder).
  Binary(topic: String, data: BitArray)
  /// A joined topic ended (client leave, kick, crash, or socket close).
  /// Delivered on every exit path.
  Closed(topic: String, reason: StopReason)
  /// A typed server-side message, sent via the socket's `Sender(msg)`
  /// (see `ConnectInfo.self` and `event.notify`). An ordinary typed send —
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
  KickTopic(topic: String)
}
```

`Ref` is opaque and single-use. A message ref is scoped to the topic it was
issued for and may be stored in the model for use from a later `update` turn
(for example, replying once an async lookup completes). A join ref is valid
only while handling that `Join` turn: it expires when the turn ends and cannot
accept or reject a later join, even when the later join uses the same topic.

## Entry points

```gleam
pub fn child_spec(
  config: Config,
  init init: fn(ConnectInfo(msg)) -> #(model, List(Effect)),
  update update: fn(model, Event(msg)) -> Next(model, msg),
) -> Result(
  #(Sockets, ChildSpecification(static_supervisor.Supervisor)),
  ConfigError,
)
```

`Sockets` is opaque and non-generic: `child_spec` captures
`model`/`msg` in closures, so transports keep receiving an unparameterized
handle through the frame-level `beryl/transport` SPI — closure capture by a
generic function, plain Gleam, with no identity FFI in this dispatch handle.
Per-topic-pattern abuse config (rate limits, join caps) lives on `Config`, built with
`beryl.config` and its `with_*` builders.

`child_spec` is the only runtime entry point. It validates `Config` and
returns a name-backed `Sockets` plus a `ChildSpecification` to embed in the
caller's own supervision tree. The handle is stable before startup and
across supervised runtime restarts; admission fails cleanly while the
runtime is unavailable, and a restart drops per-socket model state. See
[Supervision](/guides/supervision/) for the full lifecycle contract and
what `stop` does and does not tear down.

## Mapping from the deleted channel-module API

| Old (`beryl/channel`, deleted)   | App-side dispatch                        |
| --------------------------------- | ----------------------------------------- |
| `join` callback                  | `Join` event + `AcceptJoin`/`RejectJoin`  |
| `JoinOk(reply, socket)`          | `Next(model, [AcceptJoin(ref, reply)])`   |
| `handle_in` / `Reply` / `Push`   | `Message` event + `ReplyOk`/`Push`        |
| `handle_binary`                  | `Binary` event (raw undecoded path only)  |
| `handle_info` (erased `Dynamic`) | `Info(msg)` event (typed)                 |
| `terminate`                      | `Closed` event                            |
| `Stop(reason)`                   | `Stop(reason)`                            |
| assigns threading via `Socket`   | `model` threading via `Next`              |
| `beryl.register(handler)`        | routing inside the app's `update`         |
| `beryl.child_spec(config)` + registry | `beryl.child_spec(config, init:, update:)`     |
| `send_info(socket, msg)`         | `event.notify(sender, msg)`               |

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
3. **Crash blast radius.** The runtime rescues app callbacks and attributes
   failures to the event being handled. A crashing `Join` is rejected and
   the socket survives. A crashing topic-scoped `Message` (including decoded
   or raw binary delivery) closes only that topic. A crashing `Info`, which
   has no topic to attribute, tears down the whole socket. A crashing
   `Closed` callback is logged while teardown continues with the last good
   model; a crashing `init` rejects admission before the socket is registered.
   Other sockets are unaffected in every case.
4. **Presence delivery.** Lane B does not put synchronous presence calls in
   the shared runtime. Applications use a separate worker/actor and publish
   results back with broadcasts or typed `Info`; the async read-model/effect
   bundle is deferred together.
5. **Reply-outside-update.** A message `Ref` is an ordinary value that can be
   stored in the model and used from a later `update` turn (e.g. replying from
   an `Info` event once an async lookup completes), so no legitimate
   reply-later use is lost. Join refs are isolated to their `Join` turn,
   expire when it ends, and cannot complete a later same-topic join.
6. **Groups.** `beryl/group` sends to sockets sharing one app `msg` type
   through the socket's typed `Sender(msg)` — a typed send, no `Dynamic`
   anywhere in the public group API.
