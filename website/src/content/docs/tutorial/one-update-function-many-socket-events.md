---
title: One update function, many socket events
description: Handle joins, messages, binary frames, closes, replies, and ordered effects in one typed update function.
---

A WebSocket connection does more than carry app commands. A client joins
topics. It sends text events and binary frames. It leaves, or it disconnects.
It expects a reply to some of the frames it sent. Your server processes also
need a typed way to send messages into the same socket logic. Raw beryl puts
all of these cases in one `socket.Input` type. Your update function matches
every variant.

The result looks like an Elm or OTP update loop. The difference is in the
inputs. They include protocol features, and the client payload arrives with
no type.

## The five inputs

`socket.Input(message)` has five variants:

```gleam
pub type Input(message) {
  Join(topic: String, payload: Dynamic, ref: JoinRef)
  Message(topic: String, event: String, payload: Dynamic, ref: Option(ReplyRef))
  Binary(topic: String, data: BitArray)
  Closed(topic: String, reason: StopReason)
  Info(message)
}
```

This excerpt comes from
[`packages/beryl/src/beryl/socket.gleam`](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl/socket.gleam).
Each variant comes from a different place:

- `Join` asks your app to accept or reject one topic subscription.
- `Message` delivers a client event on a topic the socket has joined.
- `Binary` delivers binary data for a topic the socket has joined.
- `Closed` tells you that a joined topic has ended.
- `Info` wraps your own typed `message`. It arrives through this socket's
  `Sender`.

A socket is one client connection. A topic is one subscription string inside
that socket, such as `poll:demo`. Raw dispatch has no channel object. Your
`Model` and update function route topic strings themselves.

## Answer each join with its one-time reference

`Join(topic, payload, ref)` gives you a `socket.JoinRef`. You cannot make one
yourself, and you cannot read its contents. You can only pass it back. Return
the same value in `socket.AcceptJoin` or `socket.RejectJoin`. These exact
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
[`raw.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/raw.gleam).
`room_name` accepts a topic only when it has the form `poll:<room>` and the
room is not empty. The code never builds a ref from the topic string or from
Phoenix wire fields.

This limit is part of the contract. A `JoinRef` holds a unique runtime token.
It is valid only for the one join that is waiting for an answer. Suppose a
client joins a topic, then joins the same topic again. A late answer for the
first join cannot accept the second one.

beryl also protects you when you forget a case. If your update turn does not
return `AcceptJoin(ref, ...)` or `RejectJoin(ref, ...)` for the waiting ref,
the runtime rejects the join. A missing branch cannot leave a join half open.

## Reply references can outlive one update

`Message` includes `Option(socket.ReplyRef)`. A client can send a frame with no
message ref. Then the client does not expect a reply. When the ref is present,
your app can return `ReplyOk` or `ReplyError`.

A `ReplyRef` is not the same as a `JoinRef`:

- it matches a reply to a client message; it does not decide a join;
- you can store it in your model and answer it in a later update turn;
- you can use it only one time;
- it stays valid only while the topic that received the message stays open.

The example uses `socket.reply_ok`. When the ref is `None`, this helper returns
an empty effect list:

```gleam
poll.GetState ->
  socket.Next(
    model,
    socket.reply_ok(reply, poll.json(store.get(polls, room))),
  )
```

This excerpt comes from `handle_command` in `raw.gleam`. For error replies, the
example has a small local helper. It returns `ReplyError` only when the ref is
`Some(ref)`.

Treat both ref types as tokens. Do not compare them. Do not build them from
Phoenix fields. Pass the value back to beryl while it is still valid.

## Decode client data before using it

Client JSON arrives in `Join` and `Message` as `Dynamic`. `Dynamic` is Gleam's
type for data of unknown shape. This is on purpose. The remote client chooses
the payload, so Gleam cannot give it an app type before your code checks it.

The example decodes the payload in
[`poll.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/poll.gleam):

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

After this function, `handle_command` matches on `poll.GetState`,
`poll.Vote(choice)`, `poll.Close`, or `poll.Unsupported`. Bad JSON never
reaches the store actor. The wire payload is `Dynamic`. The domain command is
not.

This does not mean beryl loses your types. The core runtime is generic over
your `model` and `message` types. `beryl.child_spec` keeps your typed
functions inside closures. The transport handle it returns has no type
parameters. Only data from the wire is `Dynamic`.

## Effects run in list order

The vote branch shows why an update returns a list:

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

This exact excerpt comes from `raw.gleam`. When `reply` is present, beryl
runs the list as:

1. send `ReplyOk` to the browser that voted;
2. broadcast `poll_state` to every other socket on the topic.

The socket actor runs the effects in list order and writes the frames in the
same order. For one socket, list order is wire order. This is a beryl
guarantee. Lustre makes no such promise for its effects.

The same rule applies to a join. If one update returns
`[AcceptJoin(ref, None), Push(topic, "ready", payload)]`, the join
acknowledgment reaches the wire before the push. This matters. The runtime
drops a push to a topic that is not joined yet.

The rule also applies to presence effects. A separate presence actor applies
presence changes. The runtime can pause the rest of one socket's list while
that actor works. Other sockets keep going. When the presence actor is done,
the paused socket runs its remaining effects in order.

## Handle binary data, closed topics, and unknown messages

The example does not use binary frames. Its update function still matches
every variant. The `Closed` branch also releases the shared poll after the last
socket leaves the room:

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

`Closed` runs each time a topic ends, for any reason. The client can leave.
The socket can disconnect. The server can kick the client. A heartbeat can
time out. The server can shut down. In raw dispatch, this is where you remove
per-topic state. The example's store counts the sockets in each room. When the
count reaches zero, it deletes the room. Client-chosen room names do not pile
up forever. In the `Closed` turn, the runtime drops pushes to the closing
topic. Broadcasts still reach the other subscribers.

The example ignores `Binary` on purpose. A codec with a binary decoder can
turn binary frames into protocol messages. Without one, beryl delivers the raw
bytes for joined topics. The empty branch documents what this poll supports.

The `Message` branch also checks that the model knows the topic:

```gleam
case set.contains(model.topics, topic), room_name(topic) {
  True, Ok(room) ->
    handle_command(stage, polls, model, topic, room, event, payload, reply)
  _, _ -> socket.Next(model, [])
}
```

The runtime already sends client messages only for joined topics. The model
check makes the app's own routing state visible. It also shows why `Closed`
must clean up.

## Compare replies and broadcasts with two tabs

With one tab, a reply and a broadcast look the same. With two tabs in the same
room, they do not. The tab that voted gets its reply. The other tab gets
`BroadcastFrom`. Both tabs show the same new poll state. They receive it
through two different Phoenix paths.

This split helps when you design a larger protocol. A reply answers one client
request. A push is a server-sent frame to one socket. A broadcast goes to every
socket on a topic. The topic is the routing key. It is not a socket, a
channel, a `Subject`, or a `Sender`.

The next chapter adds `Info(message)`, the last input variant. It compares the
socket-scoped `Sender` with a general OTP `Subject`.

## Sources and further reading

- [`beryl/socket` source](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl/socket.gleam)
- [How beryl handles a message](/architecture/message-lifecycle/)
- [beryl raw dispatch guide](/guides/dispatch/)
- [Gleam dynamic decoding](https://hexdocs.pm/gleam_stdlib/gleam/dynamic/decode.html)

## Runnable checkpoint: step 02

```sh
cd examples/live_poll && gleam run -m live_poll/step_02
```

Open `http://localhost:8102` in two tabs. Join `demo` in both, then vote in
one tab. The voting tab updates from its `ReplyOk`. The other tab updates
from `BroadcastFrom`. Vote in each tab in turn and confirm both totals stay
the same. **Close poll now** is not available in this checkpoint.

Next: [Typed messages from the rest of your Gleam system](/tutorial/typed-messages-from-your-gleam-system/).
