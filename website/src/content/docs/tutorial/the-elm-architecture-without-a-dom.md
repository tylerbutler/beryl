---
title: The Elm Architecture, without a DOM
description: Learn Beryl's model-update architecture by building the first read-only stage of a live poll.
---

Lustre and Gleam OTP actors use the same programming model. Each one starts
with some state. Each one receives a typed message. Each one runs one function
that returns the next state and any work to do. Lustre uses this model to run
a user interface. An OTP actor uses it to run a concurrent process. Beryl uses
it to handle realtime socket traffic.

The last step is different in each case. Lustre renders a view. An actor keeps
its next state or stops. Beryl returns protocol effects. An effect can accept a
join, send a reply, or broadcast a message. Beryl also creates state once for
each connected socket, not once for the whole application.

We start with Beryl's core API. It keeps state, inputs, and effects in plain
view. First we compare the Lustre and OTP forms. Then we show the Beryl API
and map its terms onto the same model.

## Build a live poll

We will build a live poll with rooms. A browser joins a topic such as
`poll:demo`. It reads the current totals, votes for Gleam or Erlang, and sees
votes from other tabs. Later chapters add automatic closing and a second kind
of subscription.

A **topic** is a string. It names one subscription inside a WebSocket
connection. In `poll:demo`, `poll` is the kind of subscription and `demo` is
the room. One socket can join many topics. Beryl uses the topic string to route
messages and broadcasts.

Beryl does not call this subscription a channel. In Beryl, a **channel** is a
separate API built on top of topics. A later chapter introduces that API. For
now, the browser joins a topic, and your application routes it by its string.

A poll is a good example because it needs little domain code. Each browser
connection needs its own state. All browsers in the same room share one poll.
A vote also produces two kinds of output: a reply to the voter and a broadcast
to everyone else. These needs give us real reasons to use models, typed
messages, topic routing, effects, and an OTP actor that your application owns.

This chapter ends with the smallest useful checkpoint. The server accepts a
`poll:*` join and returns the current poll state. Voting, broadcasts, timers,
and channels come later, after the core loop is clear.

## The shared model-update pattern

The shared model has four parts:

1. create some state;
2. define the messages, or inputs, that can arrive;
3. handle one input against the current state;
4. return the next state and say what happens next.

Lustre, OTP actors, and Beryl use different names for the fourth part. They
also do different things with it. Parts one to three look the same in all
three.

## Start with the familiar Lustre loop

The standard Lustre example has four pieces. Here is the counter from the
Lustre overview, with full type annotations:

```gleam
fn init(_flags: Nil) -> Int {
  0
}

type Message {
  Incr
  Decr
}

fn update(model: Int, message: Message) -> Int {
  case message {
    Incr -> model + 1
    Decr -> model - 1
  }
}

```

The [Lustre for Elm developers](https://lustre.hexdocs.pm/cheatsheets/elm.html)
guide names the model type:

```gleam
type Model =
  Int
```

The view calls each module by name:

```gleam
fn view(model: Int) -> element.Element(Message) {
  let count = int.to_string(model)

  html.div([], [
    html.button([event.on_click(Incr)], [element.text(" + ")]),
    html.p([], [element.text(count)]),
    html.button([event.on_click(Decr)], [element.text(" - ")])
  ])
}
```

`init` creates the first model. `Message` lists every event that can change
the state. `update` computes the next model. `view` turns the model into
elements. Those elements can send more messages.

Some work cannot happen inside `update`. A browser may need to send an HTTP
request, start a timer, or call JavaScript. Lustre calls this work an
`Effect(Message)`. An update returns the next model and an effect. The Lustre
runtime does the work. It can then send the result back to `update` as a new
`Message`.

An OTP actor uses the same loop. The loop runs inside a concurrent process
instead of a browser.

## The same loop inside an OTP actor

A Gleam OTP actor is a process with a mailbox. It owns some state. It handles
one message at a time, in order. We keep the same counter so the only change is
the runtime:

```gleam
type Message {
  Incr
  Decr
}

fn on_message(count: Int, message: Message) -> actor.Next(Int, Message) {
  case message {
    Incr -> actor.continue(count + 1)
    Decr -> actor.continue(count - 1)
  }
}
```

The model is still an `Int`. The messages are still `Incr` and `Decr`. Two
things change: where messages come from, and what happens to the result. Lustre
gets messages from the interface and passes the next model to `view`. An actor
gets messages from its mailbox and calls `actor.continue` to store the next
state.

Here are the two side by side:

| Lustre | Gleam OTP actor |
|---|---|
| model | actor state |
| `Message` | actor mailbox message |
| `update` | `on_message` handler |
| next model and effects | `actor.Next` plus sends performed by the handler |
| `view` | no equivalent |

A Lustre message is usually an interface event or the result of an effect. An
actor message comes from another process. Both go through the same kind of
typed transition. Lustre uses the result to update the screen. The actor
runtime uses `actor.Next` to continue or stop the process.

To send a message to an actor, you use a `process.Subject(message)`. A subject
is a typed address for the actor's mailbox.

Now we can carry the same model into Beryl and give each part a socket
meaning.

## Apply the loop to sockets

Beryl gives you two ways to program a socket endpoint. The channel layer is
the recommended one. It routes each event to a handler based on the topic.
Under it sits the raw dispatch API. Raw dispatch gives every event on
a socket to one `update` function that you write.

"Raw dispatch" means your application does the routing. Your code receives
joins, client messages, binary frames, close events, and typed server messages.
Each one arrives as a `socket.Input` value. Your code decides how each input
changes the socket's model. Beryl still owns the WebSocket transport, wire
decoding, protocol checks, and effect execution.

We start with raw dispatch because it shows the full loop. A later chapter
moves the same poll to the channel layer. That chapter shows which routing work
moves out of your code.

The three domains now line up:

| Role | Lustre | Gleam OTP actor | Beryl raw dispatch |
|---|---|---|---|
| state | application model | actor state | one app-defined `Model` per socket |
| input | `Message` | actor message | `socket.Input(Message)` |
| transition | `update` | `on_message` handler | `update` |
| next step | model and optional effect | `actor.Next` | `socket.Next(model, effects)` |

Beryl asks your application for `init` and `update`. This exact excerpt comes
from `step_01.gleam`:

```gleam
beryl.child_spec(
  beryl.config(wire.phoenix_codec()),
  init: raw.init,
  update: raw.update(raw.ReadOnly, polls, clock, 60_000),
)
```

You can see it in
[`step_01.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/step_01.gleam).
`beryl.child_spec` returns two values. The first is a `beryl.Sockets` handle.
The second is a child specification for your supervisor. Your model and message
types stay inside the closures you pass in. Beryl never converts them to
`Dynamic`.

The live-poll example defines these raw types:

```gleam
pub type Message {
  ClosePoll(topic: String)
}

pub type Model {
  Model(sender: socket.Sender(Message), topics: Set(String))
}

pub fn init(info: socket.ConnectInfo(Message)) -> #(Model, List(socket.Effect)) {
  #(Model(sender: info.self, topics: set.new()), [])
}
```

This excerpt comes from
[`raw.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/raw.gleam).
Each name has one meaning:

- `Model` is the state your application keeps for one connected socket.
- `Message` is your own type for server-side events. The poll defines
  `ClosePoll` because a timer must tell a socket that one of its polls has
  ended. Another application would define its own variants.
- `socket.Effect` describes work for Beryl to do after `init` or `update`.
- `socket.ConnectInfo.self` is a sender for this socket only. It is not a
  general process `Subject`.

The type parameter links the server-message path together.
`ConnectInfo(Message)` gives you a `Sender(Message)`. When you send a value
through that sender, Beryl delivers it to `update` as `Info(Message)`. Client
frames take a different path. They arrive as the `Join`, `Message`, and
`Binary` variants of `socket.Input`. Your `Message` type never holds decoded
client data.

The `update` function has the type
`fn(Model, socket.Input(Message)) -> socket.Next(Model)`. It matches every
input variant. Beryl uses `socket.Input(Message)` where Lustre uses `Message`
and an actor uses its mailbox message. Some input variants carry client data.
`Info(Message)` carries your typed server-side data. `socket.Next(model,
effects)` continues with the next model. `socket.Stop(reason)` stops the whole
socket.

## There is no view

We have mapped state and input. The last difference is output. Beryl does not
render the model. Instead, your application returns an ordered list of
`socket.Effect` values. This exact excerpt comes from `raw.gleam`:

```gleam
socket.Next(
  Model(..model, topics: set.insert(model.topics, topic)),
  [socket.AcceptJoin(ref, None)],
)
```

Before this line, the full example registers the room in its store. This branch
then accepts a valid `poll:*` join and adds the topic to the socket's model.
Other effects can reply to a client message, push to this socket, broadcast to
subscribers, update presence, or close a topic.

Without `view`, you think about output in a new way. A change to the model
does not send a wire frame. A wire frame goes out only when an effect asks for
one. The model can also hold facts that never leave the server. The set of
topics this socket has joined is one example.

## Initialization belongs to the socket

Lustre creates one application model. An OTP actor usually creates one state
value. Beryl calls raw `init` once for every socket that connects. One socket
actor stores that socket's `Model` and runs its updates. A separate router
actor keeps the list of sockets and routes frames and broadcasts. This split
matters for blocking work and crashes. Chapter 5 covers both.

The live poll now needs an actor that your application owns. Every browser in
a room must see the same totals. So the totals cannot live in one socket's
`Model`. The example puts them in a shared `store.Store` actor and captures it
in the update closure. Each browser socket gets its own raw `Model`. All
sockets send poll operations to the same store. Per-socket state and shared
domain state stay apart.

## Where beryl differs from a frontend

The Elm architecture gives us words for pure state transitions. But Beryl is
not a frontend framework:

- there is no `view` function;
- `init` runs once per socket;
- client input arrives as `socket.Input`;
- output is an explicit list of `socket.Effect` values;
- one socket actor stores each socket's model and runs its updates.

Raw dispatch shows these facts with little extra code. It is Beryl's core. It
is the clearest place to learn joins, replies, close events, and effect order.
When an application has several channel families, you will usually move to
`beryl/channel`. That is the recommended default for multi-channel and
Phoenix-shaped systems. Chapter 4 makes that move without changing the wire
protocol.

## Sources and further reading

- [Lustre overview](https://lustre.hexdocs.pm/index.html)
- [Lustre for Elm developers](https://lustre.hexdocs.pm/cheatsheets/elm.html)
- [Gleam OTP actor module](https://gleam-otp.hexdocs.pm/gleam/otp/actor.html)
- [Gleam Erlang process module](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
- [`beryl/socket` source](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl/socket.gleam)
- [Beryl raw dispatch guide](/guides/dispatch/)

## Runnable checkpoint: step 01

```sh
cd examples/live_poll && gleam run -m live_poll/step_01
```

Open `http://localhost:8101`, keep the room as `demo`, and select **Join
poll**. The client joins `poll:demo`, requests `get_state`, and shows an open
poll with zero votes. Voting and **Close poll now** do not work yet in this
read-only checkpoint. Those pushes time out and do not change state.

Next: [One update function, many socket events](/tutorial/one-update-function-many-socket-events/).
