# The Elm architecture, without a DOM

Lustre and Gleam OTP actors apply the same programming model to different
domains. Each starts with state, receives a typed message, and runs one
function that decides the next state and any work to perform. Lustre uses that
model to manage a user interface. An OTP actor uses it to manage a concurrent
process. Beryl applies it to realtime socket traffic.

The domain determines the last step. Lustre renders a view. An actor continues
with its next state or stops. Beryl returns protocol effects such as accepting
a join, replying, or broadcasting. Beryl also initializes state once for each
connected socket rather than once for a browser application or actor process.

We will start with Beryl's core API so that state, inputs, and effects stay
visible. After comparing the Lustre and OTP forms, we will define that API and
map its terms onto the same model.

## What we are building

We will build a room-scoped live poll. A browser joins a topic such as
`poll:demo`, reads the current totals, votes for Gleam or Erlang, and sees
votes from other tabs. Later articles add automatic closing and a second kind
of subscription.

A **topic** is the string address of one subscription inside a WebSocket
connection. In `poll:demo`, `poll` identifies the kind of subscription and
`demo` identifies the room. One socket can join several topics, and Beryl uses
the topic string to route messages and broadcasts.

Beryl does not use the word channel for this subscription. Beryl reserves
that word for a separate API built on top of topics. A later article
introduces that API. For now, the browser joins a topic, and the application
routes its string address.

A poll makes the architecture visible without much domain code. Each browser
connection needs socket-local state, while every browser in the same room
shares one poll. A vote also produces two different kinds of output: a reply
to the browser that voted and a broadcast to the other subscribers. Those
requirements give us concrete reasons to use models, typed messages, topic
routing, effects, and an application-owned OTP actor.

This article ends with the smallest useful checkpoint. The server accepts a
`poll:*` join and returns the current poll state. Voting, broadcasts, timers,
and channel composition come later, after the core state-transition model is
clear.

## One model, different domains

The shared model has four parts:

1. initialize some state;
2. define the messages or inputs that can arrive;
3. handle one input against the current state;
4. return the next state and describe what happens next.

Lustre, OTP actors, and Beryl assign different names and runtime behavior to
the fourth part. The state transition stays recognizable across all three.

## Start with the familiar Lustre loop

The canonical Lustre example has four application pieces. Here is the
overview's counter with full function annotations:

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
guide makes the model type explicit:

```gleam
type Model =
  Int
```

The view uses qualified module calls:

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

`init` creates the first model. `Message` lists everything that can drive
application state. `update` computes the next model. `view` turns that model
into elements that can produce more messages.

Some work cannot happen inside a state transition. A browser may need to make
an HTTP request, start a timer, or interact with JavaScript. Lustre represents
that work as an `Effect(Message)`. An update returns the next model and an
effect value. The Lustre runtime performs the work and can feed its result
back into `update` as another `Message`.

An OTP actor keeps the same state transition. Instead of a browser event loop,
the transition runs inside a concurrent process.

## The same loop inside an OTP actor

A Gleam OTP actor applies the same state transition to a process mailbox. It
owns state and processes messages sequentially. Keeping the counter from the
Lustre example makes the change of runtime easier to see:

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

The model is still an `Int`, and the messages are still `Incr` and `Decr`.
The difference is where they come from and what happens to the result. A
Lustre runtime receives interface messages and passes the next model to
`view`. An actor receives messages from its mailbox and uses `actor.continue`
to replace its process state.

The common model becomes clearer side by side:

| Lustre | Gleam OTP actor |
|---|---|
| model | actor state |
| `Message` | actor mailbox message |
| `update` | `on_message` handler |
| next model and effects | `actor.Next` plus sends performed by the handler |
| `view` | no equivalent |

A Lustre message usually represents a user-interface event or the result of an
effect. An actor message represents communication between concurrent
processes. Both feed a typed state transition. Lustre's runtime uses the
result to update an interface. The actor runtime uses `actor.Next` to continue
or stop the process.

A `process.Subject(message)` is the typed address used to send these messages
to the actor's mailbox.

We can now carry the same model into Beryl and give each role a
socket-specific meaning.

## Beryl applies the loop to sockets

Beryl offers two ways to program a socket endpoint. The recommended channel
layer routes events to handlers selected by topic. Underneath it, the raw
app-side dispatch API gives every event for a socket to one application
`update` function.

"Raw dispatch" means the application owns that routing. Your code receives
joins, client messages, binary frames, close events, and typed server
messages as `socket.Input` values. Your code then decides how each input
changes the socket's model. Beryl still owns the WebSocket transport, wire
decoding, protocol checks, and effect execution.

We begin with raw dispatch because it exposes the complete state-transition
loop. A later article moves the same poll to the recommended channel layer and
shows which routing work moves from the application into the layer.

The three domains now line up:

| Role | Lustre | Gleam OTP actor | Beryl raw dispatch |
|---|---|---|---|
| state | application model | actor state | one app-defined `Model` per socket |
| input | `Message` | actor message | `socket.Input(Message)` |
| transition | `update` | `on_message` handler | `update` |
| next step | model and optional effect | `actor.Next` | `socket.Next(model, effects)` |

Beryl asks the application for `init` and `update`. This exact excerpt comes
from `step_01.gleam`:

```gleam
beryl.child_spec(
  beryl.config(wire.phoenix_codec()),
  init: raw.init,
  update: raw.update(raw.ReadOnly, polls, clock, 60_000),
)
```

That exact assembly appears in
[`step_01.gleam`](../../examples/blog_series/src/blog_series/step_01.gleam).
`beryl.child_spec` captures the app's concrete model and message types in
typed closures and returns a non-generic `beryl.Sockets` handle plus a child
specification. The shared runtime remains generic internally. It does not
round-trip the app model or app message through `Dynamic`.

The live-poll example's raw types are:

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
[`raw.gleam`](../../examples/blog_series/src/blog_series/raw.gleam).
The names carry specific meanings:

- `Model` is application-defined state for one connected socket.
- `Message` is the application's domain-specific type for server-side events.
  The poll defines `ClosePoll` because a timer needs to tell a socket that one
  of its polls has expired. Another application would define variants from its
  own domain.
- `socket.Effect` describes work for Beryl to interpret after `init` or
  `update`.
- `socket.ConnectInfo.self` is the socket-scoped sender. It is not a general
  process `Subject`.

The type parameter connects the server-message path:
`ConnectInfo(Message)` supplies a `Sender(Message)`, and Beryl delivers values
sent through that sender as `Info(Message)`. Client frames follow a separate
path through the `Join`, `Message`, and `Binary` variants of `socket.Input`.
The app-defined `Message` type never represents decoded client data.

The `update` function returns
`fn(Model, socket.Input(Message)) -> socket.Next(Model)` and exhaustively matches
the input inside that closure. Beryl uses `socket.Input(Message)` where Lustre
uses `Message` and an actor uses its mailbox message type. Some input variants
carry client data. `Info(Message)` carries the app's typed server-side data.
`socket.Next(model, effects)` continues with the next model. `socket.Stop(reason)`
stops the whole socket.

## There is no view

With the state and input terms mapped, the final difference is output. Beryl
does not derive output from the model by rendering it. The application returns
an ordered list of `socket.Effect` values. This exact excerpt comes from
`raw.gleam`:

```gleam
socket.Next(
  Model(..model, topics: set.insert(model.topics, topic)),
  [socket.AcceptJoin(ref, None)],
)
```

The complete example registers the room in its store. This branch then accepts
a valid `poll:*` join and records the topic in the socket's model. Other effects
can reply to a client message, push to this socket, broadcast to subscribers,
update presence, or close a topic.

The absence of `view` changes how you reason about output. A model change does
not imply a wire frame. A wire frame appears only when an effect requests one.
The model can also track facts that never need to leave the server, such as
the set of topics joined by this socket.

## Initialization belongs to the socket

Lustre initializes one application model. A typical OTP actor initializes one
actor state value. Beryl calls raw `init` once for every admitted socket connection. One socket
actor stores the returned `Model` and runs that socket's updates. A separate
router actor maintains the socket index and routes frames and broadcasts. The
distinction becomes important for blocking work and crash behavior, which the
fifth post covers.

The live poll now gives us a reason to add an application-owned actor. Every
browser connected to a room must see the same totals, so those totals cannot
belong to one socket's `Model`. The example captures a shared `store.Store`
actor in the update closure. Every browser socket gets its own raw `Model`,
while all sockets send poll operations to the same store. Per-socket state and
shared domain state remain separate.

## The first mismatch is useful

The Elm architecture supplies a vocabulary for pure state transitions, but
Beryl is not a frontend framework:

- no `view` function exists;
- `init` runs once per socket;
- client input arrives through `socket.Input`;
- output is an explicit list of `socket.Effect` values;
- one socket actor stores each socket model and runs its updates.

Raw dispatch exposes these facts with little machinery. It is Beryl's core
and the clearest place to learn joins, replies, close events, and effect order.
For an application with several channel families, you will usually move to
`beryl/channel`, the recommended default for multi-channel and Phoenix-shaped
systems. Post 4 performs that refactor without changing the wire protocol.

## Sources and further reading

- [Lustre overview](https://lustre.hexdocs.pm/index.html)
- [Lustre for Elm developers](https://lustre.hexdocs.pm/cheatsheets/elm.html)
- [Gleam OTP actor module](https://gleam-otp.hexdocs.pm/gleam/otp/actor.html)
- [Gleam Erlang process module](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
- [`beryl/socket` source](../../packages/beryl/src/beryl/socket.gleam)
- [Beryl app-side dispatch guide](../../website/src/content/docs/guides/dispatch.md)

## Runnable checkpoint: step 01

```sh
cd examples/blog_series && gleam run -m blog_series/step_01
```

Open <http://localhost:8101>, keep the room as `demo`, and select **Join
poll**. The client joins `poll:demo`, requests `get_state`, and displays an
open poll with zero votes. Voting and **Close poll now** are unavailable in
this read-only checkpoint, so those pushes time out without changing state.

Next: [One update function, many socket events](02-one-update-function-many-socket-events.md).
