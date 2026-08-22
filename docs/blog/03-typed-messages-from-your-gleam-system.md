# Typed messages from the rest of your Gleam system

Client frames are only one source of socket work. A database worker may
finish, a timer may expire, or an application actor may publish a domain
event. Beryl routes those server-side events through `socket.Sender(Message)`
and delivers them to the owning update function as `socket.Info(Message)`.

The design resembles a typed OTP send, but a Beryl sender has a narrower
contract than `process.Subject`.

## The OTP baseline

A Gleam OTP actor receives typed messages through a `process.Subject`. The
example's store wraps its subject in an opaque handle:

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
[`store.gleam`](../../examples/blog_series/src/blog_series/store.gleam).
The store's `Subject(Message)` addresses the actor's mailbox. `Join` and
`Leave` track active sockets. Other messages carry reply subjects because
`Get`, `Vote`, and `Close` are synchronous calls from the wrapper API.

The actor handler receives its current `Dict` state and one `Message`, then
returns `actor.Next`:

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

The subject can carry any protocol the actor accepts. It does not carry
Beryl's socket lifecycle rules.

## A socket sender has one destination

Raw Beryl `init` receives `socket.ConnectInfo(Message)`. Its `self` field is a
`socket.Sender(Message)`:

```gleam
pub type Model {
  Model(sender: socket.Sender(Message), topics: Set(String))
}

pub fn init(info: socket.ConnectInfo(Message)) -> #(Model, List(socket.Effect)) {
  #(Model(sender: info.self, topics: set.new()), [])
}
```

The application defines `Message` as its domain-specific vocabulary for
server-side events in the socket's update loop. The poll defines one such
event. It tells a socket that a timer has expired for one topic:

```gleam
pub type Message {
  ClosePoll(topic: String)
}
```

This `Message` is distinct from the `socket.Message` input variant, which
contains a decoded client event. A chat application might instead define
`NewChatMessage`, `UserBanned`, or other variants produced by its own actors
and workers.

The example stores `info.self` in each socket's `Model`. Beryl constructs that
sender when the socket connects. The sender wraps that socket actor's subject
and captures the socket ID. The actor uses this ID to reject a notification
after the socket has closed. The sender remains an opaque `socket.Sender`
rather than exposing the subject.

The same application-defined type appears throughout the path:

```gleam
socket.ConnectInfo(Message)
socket.Sender(Message)
socket.Input(Message)
socket.Info(ClosePoll(topic))
```

Calling `socket.notify(sender, ClosePoll(topic))` sends the typed value to the
socket actor. Beryl passes it to that socket's update function as
`Info(ClosePoll(topic))`.

Its update handles the message with this exact excerpt:

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
[`raw.gleam`](../../examples/blog_series/src/blog_series/raw.gleam).
`ClosePoll` stays typed from the call to `socket.notify` through the
`Info(ClosePoll(topic))` match. It does not become `Dynamic`.

The sender is narrower than a general `process.Subject`:

- it only permits values of the raw app's `Message` type;
- it only targets the socket update that created it;
- the runtime wraps delivery as `socket.Info(Message)`;
- it ignores delivery if that socket has disconnected;
- it does not expose mailbox selection or a general request/reply protocol.

Use `Subject` when you are defining an actor protocol. Use `socket.Sender`
when another process needs to feed typed information into one socket's update
loop.

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
[`timer.gleam`](../../examples/blog_series/src/blog_series/timer.gleam).
The timer actor owns delayed callback execution. It does not block Beryl's
socket actor for 60 seconds.

When a timed raw socket accepts a poll topic, it schedules a callback:

```gleam
case stage {
  Timed ->
    timer.after(clock, duration_ms, fn() {
      socket.notify(model.sender, ClosePoll(topic))
    })
  _ -> Nil
}
```

`step_03` passes `60_000` as `duration_ms`. After 60 seconds the timer actor
runs the callback, `socket.notify` sends `ClosePoll(topic)`, and Beryl invokes
the socket update with `Info(ClosePoll(topic))`.

The send is fire-and-forget. `socket.notify` returns `Nil`. It does not report
whether the socket remains connected. If the browser closed during the
minute, Beryl ignores the delivery. The timer actor does not need to monitor
the socket or clean up a failed request.

## Domain state remains in the store actor

The raw `Model` tracks the socket's sender and joined topics. It does not own
poll totals. Both client `Message` inputs and timer-driven `Info` inputs call
the shared `store.Store`.

That split gives each piece one job:

- Beryl's logical per-socket `Model` tracks connection-local facts.
- The store actor serializes shared poll mutations by room.
- The timer actor schedules delayed work.
- `socket.Sender` reconnects external work to one socket update.

`store.Store` is also the persistence seam. Socket code calls `get`, `vote`,
and `close` without knowing that the current actor keeps a `Dict` in memory.
The actor could keep serializing those operations while storing polls in
[Stóráil](https://hexdocs.pm/storail/) or a database. These are separate
decisions. The actor orders concurrent updates. The storage backend
determines whether state survives an application restart. A production
backend also needs an explicit policy for I/O latency and write failures.

Closing returns a descriptive result:

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

`ClosedNow` tells the caller to broadcast `poll_closed`. `AlreadyClosed`
suppresses a duplicate broadcast. Each accepted socket join schedules its own
timer, so two tabs can schedule two close messages for the same room. Only
the first close message changes the store.

## Close now uses the same state transition

In the timed stage, the client can send `close_poll`. The raw handler calls
the same `store.close` function and returns ordered effects:

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

The reply to the requesting client precedes the broadcast in the effect list.
Beryl applies effects strictly in list order, and the runtime's writes preserve
that wire order. The delayed timer may later deliver another typed `Info`, but
the idempotent store prevents a second close broadcast.

This ordering guarantee belongs to Beryl's `socket.Effect` interpreter. The
comparison with Lustre and OTP does not imply that their effects or process
sends share the same cross-abstraction ordering rules.

## `Info` has socket-wide scope

`Info(Message)` does not carry a topic automatically. The app message must include
the routing information it needs. The example defines
`ClosePoll(topic: String)` because one raw socket may join several poll topics.

This lack of topic scoping has a crash consequence. Beryl can attribute a
crashing `Message` or `Binary` callback to a topic and close only that topic.
A crashing `Info` callback has no protocol topic to attribute, so the runtime
tears down that socket. The fifth post covers the complete scoped rescue
behavior.

This design also adds a composition cost. If several raw topic families need
unrelated server message types, the app must put them in one socket-wide `Message`
union and route each variant. `beryl/channel` removes that shared union by
giving each accepted channel instance a private info type.

## Choosing the boundary

Keep slow or independently supervised work in your own processes. Send a
small typed result into Beryl when the socket update needs to decide what
state or effects come next. Each socket actor executes its update callbacks in
sequence, so sleeping, blocking I/O, or long computation inside `update`
delays that socket's messages, effects, and heartbeat checks. Other sockets
continue.

`socket.Sender` provides the typed return path without turning Beryl into the
owner of your job, store, or timer. The application still decides how to
supervise those processes.

The next post moves from one socket-wide model and message union to
heterogeneous channel handlers with private state and private info types.

## Sources and further reading

- [Gleam OTP actor module](https://gleam-otp.hexdocs.pm/gleam/otp/actor.html)
- [Gleam Erlang process module](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
- [`beryl/socket` source](../../packages/beryl/src/beryl/socket.gleam)
- [Beryl runtime architecture](../../website/src/content/docs/architecture/runtime.md)

## Runnable checkpoint: step 03

```sh
cd examples/blog_series && gleam run -m blog_series/step_03
```

Open <http://localhost:8103>, join `demo`, and vote. Select **Close poll
now** to close immediately, or leave the poll open for 60 seconds. In either
case the client receives the closed state and voting becomes disabled. If you
close the browser before the timer fires, Beryl ignores its later
`socket.notify` delivery.

Next: [Composition: raw dispatch and `beryl/channel`](04-composition-raw-dispatch-and-channels.md).
