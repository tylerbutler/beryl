# One update function, many socket events

A WebSocket connection carries more than application commands. Clients join
topics, send text events, send binary frames, leave, disconnect, and expect
replies correlated to earlier frames. Server processes also need a typed path
back into the same socket logic. Raw Beryl puts all of those cases in one
exhaustive `socket.Input` match.

The result resembles an Elm or OTP update loop, but the inputs include
protocol capabilities and an intentionally untyped wire boundary.

## The five inputs

`socket.Input(msg)` has five variants:

```gleam
pub type Input(msg) {
  Join(topic: String, payload: Dynamic, ref: JoinRef)
  Message(topic: String, event: String, payload: Dynamic, ref: Option(ReplyRef))
  Binary(topic: String, data: BitArray)
  Closed(topic: String, reason: StopReason)
  Info(msg)
}
```

This excerpt comes from
[`packages/beryl/src/beryl/socket.gleam`](../../packages/beryl/src/beryl/socket.gleam).
Each variant marks a different boundary:

- `Join` asks the application to accept or reject one topic subscription.
- `Message` carries a client event on a topic the socket has joined.
- `Binary` carries binary data associated with a joined topic.
- `Closed` reports that a joined topic ended.
- `Info` carries the app-defined typed `msg` sent through this socket's
  `Sender`.

A socket is the client connection. A topic is one subscription string inside
that socket. Raw dispatch has no channel object; the application's `Model` and
update function route topic strings themselves.

## A join ref is a capability

The `ref` in `Join(topic, payload, ref)` is an opaque `socket.JoinRef`. Return
that exact value in `socket.AcceptJoin` or `socket.RejectJoin`. These exact
excerpts come from the join branch in `raw.gleam`:

```gleam
socket.Next(
  Model(..model, topics: set.insert(model.topics, topic)),
  [socket.AcceptJoin(ref, None)],
)
```

```gleam
socket.Next(model, [
  socket.RejectJoin(
    ref,
    json.object([#("reason", json.string("unknown_topic"))]),
  ),
])
```

See the complete branch in
[`raw.gleam`](../../examples/blog_series/src/blog_series/raw.gleam).
`room_name` accepts only a non-empty `poll:<room>` topic. The code does not
reconstruct a ref from the topic or from Phoenix wire fields.

That restriction is part of the contract. A `JoinRef` carries unique runtime
identity and is valid only for its pending join. A delayed answer for an older
attempt cannot accept a replacement join on the same topic.

Beryl join handling is fail-closed. If the update turn does not return either
`AcceptJoin(ref, ...)` or `RejectJoin(ref, ...)` for the pending ref, the
runtime rejects the join automatically. Forgetting a branch cannot leave a
half-open subscription.

## Reply refs have a different lifetime

`Message` carries `Option(socket.ReplyRef)`. A client frame may omit its
message ref, in which case no correlated reply is expected. When a ref is
present, the application can return `ReplyOk` or `ReplyError`.

`ReplyRef` differs from `JoinRef`:

- it correlates a client message rather than deciding a join;
- it may be stored and answered in a later update turn;
- it is single-use;
- it stays valid only while the topic instance that received the message
  remains open.

The example uses `socket.reply_ok`, which turns `None` into an empty effect
list:

```gleam
poll.GetState ->
  socket.Next(
    model,
    socket.reply_ok(reply, poll.json(store.get(polls, room))),
  )
```

That excerpt comes from `handle_command` in `raw.gleam`. For error replies,
the example uses a small local helper that emits `ReplyError` only for
`Some(ref)`.

Treat both ref types as protocol capabilities. Do not compare or synthesize
their underlying Phoenix fields. Pass the opaque value back to Beryl while
its operation remains valid.

## `Dynamic` stops at the wire boundary

Client JSON enters `Join` and `Message` as `Dynamic`. That is intentional:
the remote client chooses the payload, so Gleam cannot assign it an
application type before validation.

The example decodes at the domain boundary in
[`poll.gleam`](../../examples/blog_series/src/blog_series/poll.gleam):

```gleam
pub fn command(event: String, payload: Dynamic) -> Command {
  case event {
    "get_state" -> GetState
    "close_poll" -> Close
    "vote" -> {
      let option = {
        use value <- decode.field("option", decode.string)
        decode.success(value)
      }
      case decode.run(payload, option) {
        Ok("gleam") -> Vote(Gleam)
        Ok("erlang") -> Vote(Erlang)
        Ok(_) | Error(_) -> Unsupported
      }
    }
    _ -> Unsupported
  }
}
```

After this function, `handle_command` matches `poll.GetState`,
`poll.Vote(choice)`, `poll.Close`, or `poll.Unsupported`. Invalid JSON shapes
do not leak into the store actor. The wire payload remains `Dynamic`; the
domain command does not.

This boundary does not imply that Beryl erases the application's model or
typed server messages. The core runtime is generic over `model` and `msg`.
`beryl.child_spec` captures concrete typed closures while exposing a
non-generic transport handle. `Dynamic` is limited to data that arrived from
the wire.

## Ordered effects produce ordered frames

The voting branch shows why an update returns a list:

```gleam
Ok(state) ->
  socket.Next(
    model,
    socket.reply_ok(reply, poll.json(state))
      |> list.append([
        socket.BroadcastFrom(topic, "poll_state", poll.json(state)),
      ]),
  )
```

This exact excerpt appears in `raw.gleam`. When `reply` is present, Beryl
interprets the list as:

1. send `ReplyOk` to the browser that voted;
2. broadcast `poll_state` to every other socket subscribed to the topic.

Effects are applied strictly in list order. The runtime actor writes the
frames, so list order is wire order for that socket. This is Beryl's contract;
the comparison does not assume an ordering contract for Lustre effects.

Join acceptance uses the same rule. If one update returns
`[AcceptJoin(ref, None), Push(topic, "ready", payload)]`, the acknowledgment
reaches the wire before the push. A push to an unjoined topic would otherwise
be dropped.

The guarantee stays observable with presence effects, though the runtime may
pause the rest of one socket's list while the separate presence actor applies
a mutation. Other sockets continue. The waiting socket resumes its remaining
effects in order.

## `Binary`, `Closed`, and unmatched messages still need branches

The example does not use binary frames, but its update remains exhaustive.
This excerpt also releases the shared poll after the room's last socket leaves:

```gleam
socket.Closed(topic, _reason) -> {
  case room_name(topic) {
    Ok(room) -> store.leave(polls, room)
    Error(_) -> Nil
  }
  socket.Next(Model(..model, topics: set.delete(model.topics, topic)), [])
}
socket.Binary(_, _) -> socket.Next(model, [])
```

`Closed` runs on every topic exit path, including a client leave, socket
disconnect, server kick, heartbeat timeout, or shutdown. Raw applications
must remove per-topic state there. The example's store reference-counts
joined sockets and deletes an empty room, so client-chosen room names do not
accumulate forever. Frames pushed to the closing topic from the `Closed` turn
are dropped, while broadcasts can still reach other subscribers.

Ignoring `Binary` is an explicit application choice. A codec with a binary
decoder can classify binary protocol messages; otherwise Beryl can deliver
raw binary data for joined topics. An exhaustive branch documents what this
poll supports.

The `Message` branch also checks that the model recorded the topic:

```gleam
case set.contains(model.topics, topic), room_name(topic) {
  True, Ok(room) ->
    handle_command(stage, polls, model, topic, room, event, payload, reply)
  _, _ -> socket.Next(model, [])
}
```

The runtime already routes client messages only to joined topics. The model
check keeps the application's own routing state explicit and makes cleanup in
`Closed` visible.

## Two tabs expose the semantics

One tab can hide the difference between reply and broadcast. With two tabs in
the same room, the origin receives its correlated reply while the peer
receives `BroadcastFrom`. Both render the same updated poll state, but they
arrive through distinct Phoenix mechanisms.

That split is useful when designing larger protocols. Replies complete a
specific client request. Pushes are server-initiated frames to one socket.
Broadcasts fan out by topic. A topic is the routing key; it is not a socket,
channel, `Subject`, or `Sender`.

The next post adds `Info(msg)`, the remaining input variant, and compares its
socket-scoped `Sender` with a general OTP `Subject`.

## Sources and further reading

- [`beryl/socket` source](../../packages/beryl/src/beryl/socket.gleam)
- [Beryl message lifecycle](../../website/src/content/docs/architecture/message-lifecycle.md)
- [Beryl app-side dispatch guide](../../website/src/content/docs/guides/dispatch.md)
- [Gleam dynamic decoding](https://hexdocs.pm/gleam_stdlib/gleam/dynamic/decode.html)

## Runnable checkpoint: step 02

```sh
cd examples/blog_series && gleam run -m blog_series/step_02
```

Open <http://localhost:8102> in two tabs. Join `demo` in both, then vote in
one tab. The voting tab updates from its `ReplyOk`; the other tab updates from
`BroadcastFrom`. Alternate votes between tabs and confirm both totals stay in
sync. **Close poll now** remains unavailable in this checkpoint.

Next: [Typed messages from the rest of your Gleam system](03-typed-messages-from-your-gleam-system.md).
