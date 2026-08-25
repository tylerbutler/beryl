---
title: "Composition: Raw Dispatch and beryl/channel"
description: Refactor a socket-wide update function into heterogeneous channel handlers with private state and typed messages.
---

Elm and Lustre applications compose child logic by making the parent own the
combined model and message space. The parent stores the child models and adds
each child message type to a union. It maps child messages into that union and
routes them to the correct update function.

Raw Beryl supports the same pattern. It is type-safe and gives one update
complete control across every topic on a socket. Its cost grows with the
number of unrelated topic families. `beryl/channel` moves that recurring
router into a public layer while keeping the same core runtime.

## Raw composition is a parent router

Imagine a socket serving polls, document cursors, and account alerts. In raw
dispatch, the app-defined `Model` must represent all three concerns. The
app-defined `Message` must include each server-side message. The update function
then routes:

- `Join` by topic pattern;
- `Message` and `Binary` by topic and event;
- `Closed` to the correct cleanup branch;
- `Info` by the app's message union.

This is the server-side equivalent of a Lustre parent model and parent
`Message` union. The application performs the mapping rather than a DOM event
constructor. It works well when one topic family dominates or when behavior
must coordinate across topics in one ordered effect list.

The live-poll example already shows the beginnings of that cost:

```gleam
pub type Stage {
  ReadOnly
  Voting
  Timed
}

pub type Message {
  ClosePoll(topic: String)
}

pub type Model {
  Model(sender: socket.Sender(Message), topics: Set(String))
}
```

This excerpt comes from
[`raw.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/raw.gleam).
Adding a second unrelated guide topic would widen `Message`, add state or routing
metadata to `Model`, and add more branches to the same update.

That is not a type-safety defect. It is the explicit price of making the app
own the complete socket router.

## The channel layer supplies the router

`beryl/channel` is the recommended default for multi-channel and
Phoenix-shaped applications. The example's fourth checkpoint starts it
with:

```gleam
let assert Ok(#(sockets, spec)) =
  channel.child_spec(
    beryl.config(wire.phoenix_codec()),
    handlers: channels.handlers(polls, clock, 60_000),
  )
```

This excerpt comes from
[`step_04.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/step_04.gleam).
`channel.child_spec` accepts the same core `beryl.Config` and returns the same
kind of `beryl.Sockets` handle and supervised child specification as
`beryl.child_spec`.

The handler table contains two values:

```gleam
pub fn handlers(
  polls: store.Store,
  clock: timer.Timer,
  duration_ms: Int,
) -> List(channel.Handler) {
  [poll_channel(polls, clock, duration_ms), guide_channel()]
}
```

One handler owns `poll:*`. The other owns `guide`. They use different state
and info types but still fit in `List(channel.Handler)`.

## A handler creates one channel instance

The poll handler matches a topic pattern and receives a
`channel.JoinContext`:

```gleam
fn poll_channel(
  polls: store.Store,
  clock: timer.Timer,
  duration_ms: Int,
) -> channel.Handler {
  channel.handler("poll:*", fn(context) {
    let room = case context.params {
      [room] -> room
      _ -> ""
    }
    store.join(polls, room)
    timer.after(clock, duration_ms, fn() {
      channel.notify(context.self, ClosePoll(room))
    })

    channel.accept(room)
    |> channel.on_message(fn(room, message) {
      handle_message(polls, room, message)
    })
    |> channel.on_info(fn(room, message) {
      let ClosePoll(_topic) = message
      case store.close(polls, room) {
        store.ClosedNow(state) ->
          channel.next(room, [
            channel.broadcast("poll_closed", poll.json(state)),
          ])
        store.AlreadyClosed(_) | store.RoomNotFound -> channel.stay(room)
      }
    })
    |> channel.on_terminate(fn(room, _reason) {
      store.leave(polls, room)
      []
    })
  })
}
```

This exact excerpt comes from
[`channels.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/channels.gleam).
The concepts now have channel-specific names:

- `channel.Handler` pairs a topic pattern with a join callback.
- `channel.JoinContext` bundles the concrete topic, wildcard `params`, join
  payload, connection data, and this join's typed sender.
- `channel.accept` supplies the channel's initial private state.
- `channel.Next` returns the next private state and ordered actions.
- `channel.Action` describes work on this channel's own topic.

The private state here is a `String` room name. The private info type is
`PollInfo`, whose only variant is `ClosePoll`. Neither type joins a
socket-wide union. `on_terminate` releases the room from the shared store.
The store removes its poll after the last socket leaves.

## Closure sealing makes heterogeneous handlers possible

`channel.Handler` is opaque and non-generic. Internally, `channel.handler`
captures the typed join callback. `channel.handler` seals the state into the
typed message, info, and terminate callbacks. Each `channel.next`
seals the next state into the same callback set.

The layer does not coerce channel state or info messages through `Dynamic`.
It uses closures to preserve each handler's concrete types. The socket-level
router owns a sealed envelope for channel info delivery. It adds the topic and
join generation to the envelope. The router checks this information before the
owning closure opens the value.

This sealing is separate from the core runtime's generic dispatch. At the core
level, `beryl.child_spec` captures the app's model and message types in
monomorphic closures. At the channel layer, each handler separately seals its
private state and info type. Client payloads remain `Dynamic` at the wire
boundary in both APIs.

The layer itself imports and calls Beryl's public core API. It supplies a raw
`init` and `update` pair to `beryl.child_spec`. It does not bypass the runtime
or restore the superseded type-erased channel registry described in ADR 0001.

## The second handler proves heterogeneity

The guide handler does not share the poll handler's state or info type:

```gleam
type GuideInfo {
  Ready(String)
}

fn guide_channel() -> channel.Handler {
  channel.handler("guide", fn(context) {
    timer_message(context.self)
    channel.accept(0)
    |> channel.on_info(fn(count, message) {
      let Ready(text) = message
      channel.next(count + 1, [
        channel.push(
          "tip",
          json.object([
            #("text", json.string(text)),
            #("delivery", json.int(count + 1)),
          ]),
        ),
      ])
    })
  })
}
```

This exact excerpt also comes from `channels.gleam`. The guide channel uses
`Int` state and `GuideInfo`. The poll channel uses `String` state and
`PollInfo`. The application composes both as handler values without defining
`Model(PollState, GuideState)` or `Message(PollMessage | GuideMessage)`.

The browser joins `guide` after joining its poll topic. The guide's typed
message produces a `tip` push, which the client stores as the status
element's title.

## Actions are scoped and phase-typed

Raw `socket.Effect` values name a topic:

```gleam
socket.BroadcastFrom(topic, "poll_state", poll.json(state))
```

A channel action does not:

```gleam
channel.broadcast_from("poll_state", poll.json(state))
```

The current channel supplies the topic. That makes most callback code shorter
and prevents an action from accidentally targeting another topic.

The restriction is deliberate. Raw dispatch can coordinate across topics in
one observable effect list. Channel callbacks return actions scoped to their
own channel. Cross-topic publishing uses the external `beryl.Sockets` APIs or
an application actor that owns the handle.

Channel actions also carry a phase parameter. Active callbacks can reply,
push, broadcast, track presence, or close. `on_terminate` returns closing
actions, where replies, pushes, and presence tracking do not type-check.
Broadcasts and presence cleanup remain available after the runtime removes
the instance.

The example defines `on_terminate` to release its room from the shared store.
Its timer-driven `on_info` and client-driven `on_message` return active
actions. Termination returns only the closing actions allowed in that phase.

## Ordered actions lower to ordered effects

The voting branch returns:

```gleam
Ok(state) ->
  channel.next(room, [
    channel.reply_ok(message.reply, poll.json(state)),
    channel.broadcast_from("poll_state", poll.json(state)),
  ])
```

The layer lowers these actions one-to-one into core `socket.Effect` values in
the same order. The same runtime interprets them, so the reply still precedes
the broadcast.

Accepted joins can attach actions with `channel.with_actions`. The layer emits
the join acknowledgment first, then those actions. A push cannot overtake its
own join acknowledgment.

## Pick one API per endpoint

Raw dispatch remains the clearest teaching example and the core programming
model. Choose it for a single topic family, a compact protocol, or direct
cross-topic coordination.

Choose `beryl/channel` by default when a socket serves several topic
namespaces, when porting Phoenix Channels, or when handlers should keep
private state and info types. The two APIs share the wire codec, runtime,
presence, PubSub, abuse controls, and transport. Pick one programming model
for a socket endpoint. Do not embed hand-written raw update logic inside a
channel system.

The final chapter follows both APIs below their callbacks into the shared runtime
and explains where the Elm analogy stops helping.

## Sources and further reading

- [Lustre for Elm developers](https://lustre.hexdocs.pm/cheatsheets/elm.html)
- [`beryl/channel` source](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl/channel.gleam)
- [Beryl channels guide](/guides/channels/)
- [Choose a Beryl API](/choosing-an-api/)
- [ADR 0002: app-side dispatch](https://github.com/tylerbutler/beryl/blob/main/docs/adr/0002-app-side-dispatch.md)
- [ADR 0003: layered channel API](https://github.com/tylerbutler/beryl/blob/main/docs/adr/0003-layered-channel-api.md)

## Runnable checkpoint: step 04

```sh
cd examples/live_poll && gleam run -m live_poll/step_04
```

Open `http://localhost:8104` in two tabs, join `demo`, and vote. Replies and
peer broadcasts behave as in step 03, but `beryl/channel` now owns routing and
private channel state. Select **Close poll now** or wait 60 seconds. The
browser also joins the heterogeneous `guide` handler. Inspect the status
paragraph's `title` attribute to see its typed info message.

Next: [Where the analogy ends](/tutorial/where-the-analogy-ends/).
