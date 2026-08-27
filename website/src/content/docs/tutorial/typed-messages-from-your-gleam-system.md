---
title: Typed messages from your Gleam system
description: Send typed server-side events from actors and timers into the socket update loop.
---

Client frames are not the only source of socket work. A database worker can
finish. A timer can expire. An actor in your app can publish an event. beryl
calls these server-side events. It routes them through a
`socket.Sender(Message)`. The socket's update function receives them as
`socket.Info(Message)`.

This looks like a typed OTP send. But a beryl sender can do less than a
`process.Subject`. This chapter shows the difference.

## Start with an OTP actor

A Gleam OTP actor is a process with a mailbox. It receives typed messages
through a `process.Subject`. The example's store keeps its subject inside an
opaque type, so callers cannot use the subject directly:

```gleam
pub opaque type Store {
  Store(subject: Subject(Message))
}

type Message {
  Join(room: String)
  Leave(room: String)
  Get(room: String, reply: Subject(poll.Poll))
  Vote(
    room: String,
    choice: poll.Choice,
    reply: Subject(Result(poll.Poll, poll.VoteError)),
  )
  Close(room: String, reply: Subject(CloseResult))
}
```

This excerpt comes from
[`store.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/store.gleam).
The `Subject(Message)` is the address of the actor's mailbox. `Join` and
`Leave` count the active sockets in a room. `Get`, `Vote`, and `Close` carry a
`reply` subject. The caller waits for an answer on that subject.

The actor's handler receives its current state and one `Message`. It returns
`actor.Next`:

```gleam
Vote(room, choice, reply) -> {
  let #(current, polls) = find(state.polls, room)
  case poll.vote(current, choice) {
    Ok(updated) -> {
      process.send(reply, Ok(updated))
      actor.continue(
        State(..state, polls: dict.insert(polls, room, updated)),
      )
    }
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(State(..state, polls: polls))
    }
  }
}
```

A subject can carry any message type the actor accepts. It knows nothing about
beryl sockets or when they close.

## A socket sender has one destination

When a socket connects, beryl calls your raw `init` with a
`socket.ConnectInfo(Message)`. Its `self` field is a `socket.Sender(Message)`:

```gleam
pub type Model {
  Model(sender: socket.Sender(Message), topics: Set(String))
}

pub fn init(info: socket.ConnectInfo(Message)) -> #(Model, List(socket.Effect)) {
  #(Model(sender: info.self, topics: set.new()), [])
}
```

You define `Message`. It is the set of server-side events your update function
can receive. The poll defines one event. It tells a socket that the timer for
one topic has expired:

```gleam
pub type Message {
  ClosePoll(topic: String)
}
```

Do not confuse this `Message` with `socket.Message`. `socket.Message` is an
input variant that holds a decoded client event. Your own `Message` holds
events from your actors and workers. A chat app might define `NewChatMessage`
or `UserBanned` here.

The example stores `info.self` in the socket's `Model`. beryl makes the sender
when the socket connects. It knows which socket actor it belongs to. If that
socket has closed, the sender drops the message. You never see the subject
inside it.

Your `Message` type appears at each step of the path:

<!-- snippet-check: skip -->
```gleam
socket.ConnectInfo(Message)
socket.Sender(Message)
socket.Input(Message)
socket.Info(ClosePoll(topic))
```

To send an event, call `socket.notify(sender, ClosePoll(topic))`. beryl
delivers it to the socket's update function as `Info(ClosePoll(topic))`.

The update function handles it like this:

```gleam
socket.Info(ClosePoll(topic)) ->
  case room_name(topic) {
    Ok(room) -> {
      let effects = case store.close(polls, room) {
        store.ClosedNow(state) ->
          [socket.Broadcast(topic, "poll_closed", poll.json(state))]
        store.AlreadyClosed(_) | store.RoomNotFound -> []
      }
      socket.Next(model, effects)
    }
    Error(_) -> socket.Next(model, [])
  }
```

These excerpts come from
[`raw.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/raw.gleam).
`ClosePoll` keeps its type from `socket.notify` to the `Info` match. It never
becomes `Dynamic`.

A sender can do less than a `process.Subject`:

- It accepts only values of your `Message` type.
- It sends only to the socket that made it.
- beryl wraps each value as `socket.Info(Message)`.
- It drops the value if the socket has disconnected.
- It has no request/reply protocol and no mailbox selection.

Use a `Subject` when you define an actor's protocol. Use a `socket.Sender`
when another process must send a typed event into one socket.

## The timer stays outside the runtime

The example has a small timer actor:

```gleam
pub opaque type Timer {
  Timer(subject: Subject(Message))
}

type Message {
  Run(fn() -> Nil)
}

pub fn after(timer: Timer, milliseconds: Int, action: fn() -> Nil) -> Nil {
  let _ = process.send_after(timer.subject, milliseconds, Run(action))
  Nil
}
```

This exact excerpt comes from
[`timer.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/timer.gleam).
The timer actor runs the callback after the delay. The socket actor does not
wait 60 seconds. It stays free to handle other work.

When a timed socket accepts a poll topic, it schedules a callback:

```gleam
case stage {
  Timed ->
    timer.after(clock, duration_ms, fn() {
      socket.notify(model.sender, ClosePoll(topic))
    })
  ReadOnly | Voting -> Nil
}
```

`step_03` sets `duration_ms` to `60_000`. After 60 seconds, the timer actor
runs the callback. The callback calls `socket.notify`. beryl then calls the
socket's update function with `Info(ClosePoll(topic))`.

`socket.notify` is fire-and-forget. It returns `Nil`. It does not tell you if
the socket is still connected. If the browser closed during that minute, beryl
drops the message. The timer actor does not need to watch the socket or clean
up after it.

## Keep shared poll state in the store actor

The raw `Model` holds the sender and the set of joined topics. It does not hold
vote counts. Both client events and timer events call the shared
`store.Store`.

Each part has one job:

- The socket `Model` holds facts about one connection.
- The store actor applies poll changes one at a time for each room.
- The timer actor runs delayed work.
- The `socket.Sender` sends the result back into one socket.

`store.Store` also hides where the data lives. Socket code calls `get`, `vote`,
and `close`. It does not know that the actor keeps a `Dict` in memory. The
actor could keep polls in [Stóráil](https://hexdocs.pm/storail/) or a database
instead. The actor still puts the updates in order. The storage decides if
the data survives a restart. A real backend also needs a plan for slow I/O and
failed writes.

The close operation returns a result that says what happened:

```gleam
pub type CloseResult {
  ClosedNow(Poll)
  AlreadyClosed(Poll)
}

pub fn close(poll: Poll) -> CloseResult {
  case poll.status {
    Open -> ClosedNow(Poll(..poll, status: Closed))
    Closed -> AlreadyClosed(poll)
  }
}
```

`ClosedNow` tells the caller to broadcast `poll_closed`. `AlreadyClosed` tells
the caller not to broadcast again. Each socket join sets its own timer. Two
tabs on the same room set two timers. Only the first `ClosePoll` changes the
store.

## Reuse the same close operation

In the timed stage, a client can send `close_poll`. The raw handler calls the
same `store.close` function. It returns effects in order:

```gleam
Timed -> {
  case store.close(polls, room) {
    store.ClosedNow(state) ->
      socket.Next(
        model,
        list.append(
          socket.reply_ok(reply, poll.json(state)),
          [socket.Broadcast(topic, "poll_closed", poll.json(state))],
        ),
      )
    store.AlreadyClosed(state) ->
      socket.Next(model, socket.reply_ok(reply, poll.json(state)))
    store.RoomNotFound -> socket.Next(model, [])
  }
}
```

The reply comes before the broadcast in the list. beryl runs effects in list
order. The wire sees them in that order too. The timer can still send a later
`Info`. But `store.close` is safe to call twice, so there is no second
broadcast.

This order guarantee is a beryl rule. Lustre effects and OTP sends have their
own rules. Do not assume they order work the same way.

## Include the topic in each `Info` message

An `Info(Message)` does not carry a topic. Your message must carry the routing
data it needs. The example defines `ClosePoll(topic: String)` because one raw
socket can join several poll topics.

This has one effect on crashes. When a `Message` or `Binary` callback crashes,
beryl knows the topic. It closes only that topic. When an `Info` callback
crashes, beryl has no topic. It closes the whole socket. Chapter 5 explains the
full crash behavior.

It also has a cost when you compose. If several topic families need different
server-side events, you must put them all in one `Message` type. Your update
function must route each variant. `beryl/channel` removes this shared type.
Each channel gets its own private info type.

## Keep slow work outside socket callbacks

Keep slow work in your own processes. Keep work that needs its own supervisor
there too. Send a small typed result into beryl when the socket must decide on
new state or effects. Each socket actor runs its update callbacks one at a
time. If `update` sleeps, blocks on I/O, or does long work, that socket's
messages, effects, and heartbeat checks wait. Other sockets are not affected.

`socket.Sender` gives you a typed way back into the socket. beryl does not
become the owner of your job, store, or timer. Your app still decides how to
supervise those processes.

The next chapter moves from one socket-wide `Model` and `Message` to channel
handlers. Each handler keeps its own state and info types.

## Sources and further reading

- [Gleam OTP actor module](https://gleam-otp.hexdocs.pm/gleam/otp/actor.html)
- [Gleam Erlang process module](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
- [`beryl/socket` source](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl/socket.gleam)
- [beryl runtime architecture](/architecture/runtime/)

## Runnable checkpoint: step 03

```sh
cd examples/live_poll && gleam run -m live_poll/step_03
```

Open `http://localhost:8103`, join `demo`, and vote. Select **Close poll now**
to close the poll at once, or wait 60 seconds. In both cases, the client
receives the closed state and voting stops. If you close the browser before
the timer fires, beryl drops the later `socket.notify` message.

Next: [Composition: raw dispatch and `beryl/channel`](/tutorial/composition-raw-dispatch-and-channels/).
