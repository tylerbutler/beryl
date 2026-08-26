---
title: "Move from raw dispatch to channel handlers"
description: Move from one socket-wide update function to channel handlers that each keep their own state and message type.
---

In Elm and Lustre, a parent component owns its children. The parent model
stores each child model. The parent message type has one variant for each child
message type. The parent update function looks at the message and sends it to
the correct child.

Raw Beryl works the same way. One update function sees every topic on a socket.
This is type-safe, and it gives you full control. But the work grows with each
new topic family you add. `beryl/channel` does that routing for you. It runs on
the same core runtime.

## Raw dispatch makes your update function route topics

Imagine one socket that serves polls, document cursors, and account alerts. In
raw dispatch, your `Model` must hold state for all three. Your `Message` type
must include every server-side message for all three. Your update function must
then route each input:

- `Join` by topic pattern;
- `Message` and `Binary` by topic and event name;
- `Closed` to the correct cleanup code;
- `Info` by your own message type.

This is the same job a Lustre parent does. Here, your code does the mapping
instead of a DOM event. This works well when one topic family does most of the
work. It also works well when one effect list must coordinate several topics.

The live-poll example already shows the start of this cost:

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
Add a second, unrelated `guide` topic and three things grow. `Message` gets
more variants. `Model` gets more fields. The update function gets more
branches.

This is not a type-safety problem. It is the price you pay when your app owns
the full socket router.

## Channel handlers route topics for you

For apps with many topic families, or apps shaped like Phoenix Channels, use
`beryl/channel`. Step 4 of the example starts it like this:

```gleam
let assert Ok(#(sockets, spec)) =
  channel.child_spec(
    beryl.config(wire.phoenix_codec()),
    handlers: channels.handlers(polls, clock, 60_000),
  )
```

This excerpt comes from
[`step_04.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/step_04.gleam).
`channel.child_spec` takes the same `beryl.Config` as `beryl.child_spec`. It
returns the same two values: a `beryl.Sockets` handle and a child specification
for your supervisor.

You give it a list of handlers. The example has two:

```gleam
pub fn handlers(
  polls: store.Store,
  clock: timer.Timer,
  duration_ms: Int,
) -> List(channel.Handler) {
  [poll_channel(polls, clock, duration_ms), guide_channel()]
}
```

One handler owns the `poll:*` topics. The other owns `guide`. Each one uses a
different state type and a different info type. Both still fit in one
`List(channel.Handler)`. The next sections show how.

## A handler creates one channel for each join

A handler has two parts: a topic pattern and a join function. When a client
joins a topic that matches the pattern, Beryl calls the join function with a
`channel.JoinContext`. The join function returns the new channel.

```gleam
pub type PollInfo {
  ClosePoll
}

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
      channel.notify(context.self, ClosePoll)
    })

    channel.accept(room)
    |> channel.on_message(fn(room, message) {
      handle_message(polls, room, message)
    })
    |> channel.on_info(fn(room, message) {
      let ClosePoll = message
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
Read it from the top:

- `channel.handler` pairs the pattern `poll:*` with the join function.
- `context.params` holds the part of the topic that matched `*`. For
  `poll:demo`, that is `["demo"]`.
- `context.self` is a typed sender for this channel. The timer uses it to send
  `ClosePoll` later.
- `channel.accept(room)` accepts the join. The argument is the channel's
  starting state. Here, the state is the room name.
- Each `on_*` call adds a callback. A callback receives the current state and
  returns the next state plus a list of actions.
- `on_terminate` runs when the channel closes. Here, it tells the store that
  this socket has left the room.

The state type is `String`. The info type is `PollInfo`. Neither type appears
in a socket-wide `Model` or `Message`. They belong to this handler only.

## Keep different state types in one handler list

`channel.Handler` has no type parameters. This is what lets the poll handler
and the guide handler share one list.

Here is how it works. `channel.handler` stores your join function inside a
closure. When the join function runs, `channel.accept` and each `on_*` call
store the state and callbacks inside more closures. Each `channel.next` does
the same with the new state. The types stay concrete inside those closures.
From the outside, every handler has the same type.

Beryl does not turn your state or info messages into `Dynamic`. Only the
client payload is `Dynamic`, because it comes from the wire. That is true for
both APIs.

The channel layer is built on the public core API. It gives `beryl.child_spec`
its own raw `init` and `update` pair. It does not go around the runtime.

## Add a handler with different types

The guide handler uses different types from the poll handler:

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

This exact excerpt also comes from `channels.gleam`. The guide channel uses an
`Int` for state and `GuideInfo` for info. The poll channel uses a `String` and
`PollInfo`. You do not write `Model(PollState, GuideState)` or
`Message(PollMessage | GuideMessage)`. You put the two handlers in a list.

The browser joins `guide` after it joins its poll topic. The `Ready` message
becomes a `tip` push. The client stores the tip as the `title` of its status
element.

## Actions apply to one channel

A raw effect names its topic:

```gleam
socket.BroadcastFrom(topic, "poll_state", poll.json(state))
```

A channel action does not:

```gleam
channel.broadcast_from("poll_state", poll.json(state))
```

The channel already knows its topic. Your callback code is shorter, and an
action cannot go to the wrong topic by mistake.

This is a real limit. A raw update function can act on several topics in one
effect list. A channel callback can act only on its own channel. To publish
across topics, use the `beryl.Sockets` handle from outside the channel, or from
an actor that owns the handle.

Actions also depend on when they run. In `on_message` and `on_info`, a callback
can reply, push, broadcast, track presence, or close. In `on_terminate`, the
channel is closing. A reply, push, or presence track makes no sense there, and
the compiler rejects them. Broadcast and presence cleanup still work.

## beryl runs actions in list order

The vote branch returns:

```gleam
Ok(state) ->
  channel.next(room, [
    channel.reply_ok(message.reply, poll.json(state)),
    channel.broadcast_from("poll_state", poll.json(state)),
  ])
```

The channel layer turns each action into one core `socket.Effect`. It keeps the
order. The same runtime runs them, so the reply goes out before the broadcast.

A join can also return actions. Use `channel.with_actions` on an accepted join.
Beryl sends the join acknowledgment first, then those actions. A push can never
arrive before its own join acknowledgment.

## Pick one API for each endpoint

Raw dispatch is the core programming model and the clearest one to learn from.
Choose it when you have one topic family, a small protocol, or work that spans
topics.

Choose `beryl/channel` when a socket serves several topic namespaces, when you
port Phoenix Channels, or when each handler should keep its own state and info
types. Both APIs share the wire codec, runtime, presence, PubSub, abuse
controls, and transport. Use one API for each socket endpoint. Do not mix raw
update logic into a channel system.

The next chapter follows both APIs down into the shared runtime. It shows where
the Elm analogy stops.

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
peer broadcasts work as in step 03. Now `beryl/channel` owns the routing and
the channel state. Select **Close poll now** or wait 60 seconds. The browser
also joins the `guide` channel. Inspect the `title` attribute of the status
paragraph to see its typed info message.

Next: [Where the analogy ends](/tutorial/where-the-analogy-ends/).
