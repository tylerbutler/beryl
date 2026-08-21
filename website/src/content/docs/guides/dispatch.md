---
title: App-Side Dispatch
description: Route joins, messages, binary frames, close events, and typed server messages in one update function.
---

Raw **app-side dispatch** is beryl's core programming model. Build one
supervised runtime with `beryl.child_spec`. Build a per-socket model in `init`.
Route each socket event in one `update` function. For multi-channel or
Phoenix-style apps, use the recommended
[`beryl/channel` layer](/guides/channels/).

Your application routes `socket.Input` values and returns
`socket.Next(model, effects)`. You do not need a registry or a per-topic module
lifecycle.

## The app entry point

```gleam
import beryl
import beryl/socket as socket
import beryl/wire
import gleam/otp/static_supervisor

let assert Ok(#(sockets, spec)) =
  beryl.child_spec(
    beryl.config(wire.phoenix_codec()),
    init: init,
    update: update,
  )
let assert Ok(_root) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(spec)
  |> static_supervisor.start()
```

- `init` runs once per socket connection and returns `#(model, List(socket.Effect))`.
- `update` receives every `socket.Input(msg)` for that socket and returns either:
  - `socket.Next(model, effects)` to continue, or
  - `socket.Stop(reason)` to close the whole socket.

`socket.Input(msg)` is the whole contract:

- `socket.Join(topic, payload, ref)`
- `socket.Message(topic, event, payload, ref)`
- `socket.Binary(topic, data)`
- `socket.Closed(topic, reason)`
- `socket.Info(msg)`

## Topics and patterns

Topics are colon-delimited strings. Use `beryl/topic` to route them in
`update`.

```gleam
import beryl/topic

topic.parse_pattern("room:lobby")
// -> Exact("room:lobby")

topic.parse_pattern("room:*")
// -> Wildcard("room:")

topic.parse_pattern("document:*:ops")
// -> SegmentWildcard(["document", "*", "ops"])

topic.extract_id(topic.parse_pattern("room:*"), "room:lobby")
// -> Ok("lobby")

topic.extract_wildcards(
  topic.parse_pattern("document:*:*"),
  "document:tenant-a:doc-42",
)
// -> Ok(["tenant-a", "doc-42"])
```

For one namespace, match in `update`. When several namespaces share a socket,
use [`beryl/channel`](/guides/channels/). See
[Routing many topics from one app](#routing-many-topics-from-one-app).

## Single-topic example

This example accepts `room:*` joins and replies to `ping`. It broadcasts
`typing` to all clients except the sender. The model tracks joined topics. The
app also handles typed server-side `Info` messages.

```gleam
import beryl/socket as socket
import beryl/topic
import gleam/json
import gleam/list
import gleam/option.{Some}

pub type Msg {
  Tick(Int)
}

pub type Model {
  Model(joined_topics: List(String), self: socket.Sender(Msg))
}

fn init(info: socket.ConnectInfo(Msg)) -> #(Model, List(socket.Effect)) {
  #(Model(joined_topics: [], self: info.self), [])
}

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model) {
  let room_pattern = topic.parse_pattern("room:*")

  case ev {
    socket.Join(topic_name, _payload, ref) ->
      case topic.extract_id(room_pattern, topic_name) {
        Ok(room_id) ->
          socket.Next(
            Model(
              joined_topics: [topic_name, ..model.joined_topics],
              self: model.self,
            ),
            [
              socket.AcceptJoin(
                ref,
                Some(json.object([
                  #("room_id", json.string(room_id)),
                ])),
              ),
              socket.Push(
                topic_name,
                "system:joined",
                json.object([#("room_id", json.string(room_id))]),
              ),
            ],
          )

        Error(_) ->
          socket.Next(
            model,
            [
              socket.RejectJoin(
                ref,
                json.object([
                  #("reason", json.string("unknown topic")),
                ]),
              ),
            ],
          )
      }

    socket.Message(_topic_name, "ping", _payload, Some(ref)) ->
      socket.Next(
        model,
        [
          socket.ReplyOk(
            ref,
            json.object([#("status", json.string("ok"))]),
          ),
        ],
      )

    socket.Message(topic_name, "typing", _payload, _ref) ->
      socket.Next(
        model,
        [socket.BroadcastFrom(topic_name, "typing", json.object([]))],
      )

    socket.Closed(topic_name, _reason) ->
      socket.Next(
        Model(
          ..model,
          joined_topics: list.filter(model.joined_topics, fn(topic) {
            topic != topic_name
          }),
        ),
        [],
      )

    socket.Info(Tick(at)) -> {
      let effects =
        list.map(model.joined_topics, fn(topic_name) {
          socket.Push(
            topic_name,
            "tick",
            json.object([#("at", json.int(at))]),
          )
        })
      socket.Next(model, effects)
    }

    socket.Binary(_topic_name, _data) ->
      socket.Next(model, [])

    socket.Message(_, _, _, None) ->
      socket.Next(model, [])
  }
}
```

A few important details:

- Joins are explicit: return `socket.AcceptJoin(ref, reply)` or `socket.RejectJoin(ref, reason)`.
- Message replies are explicit too: use `socket.ReplyOk` / `socket.ReplyError` when a client ref is present.
- `socket.Closed(topic, reason)` replaces per-topic cleanup hooks. Prune topic-local state there.
- `socket.Info(msg)` is just a typed message from your own server code.

## Routing many topics from one app

Use [`beryl/channel`](/guides/channels/). Register a list of channel handlers
and the layer routes every socket event to the channel that owns its topic.
Each channel keeps its own private state and server-side message type, so
channels that share no types compose in one list, and there is no socket-wide
model, message union, or `update` function to write.

The `showcase` example composes three topic families with `beryl/channel`.
The `cursors` example stays on raw dispatch and matches its single
`cursor:*` pattern directly with `beryl/topic`.

### Migrating from `beryl/socket/router`

There is no replacement router API. Let the compiler expose every old import
and choose one of the two models:

- For one topic family, match `socket.Input` directly and use
  `topic.matches` or `topic.extract_wildcards`.
- For several topic families, replace each `Namespace` with a
  `channel.Handler`, move its state into `channel.accept`, and start the table
  with `channel.child_spec`.

Delete calls to `namespace`, `accept_only`, `unknown_topic`, and `route`; do
not rebuild the same abstraction locally. `gleam check` then points to the
remaining `Match` and `Namespace` types that need direct topic values or
`JoinContext.params`.

## Typed server-side messages

`socket.ConnectInfo.self` gives each socket a typed `socket.Sender(msg)`. A
process can keep the sender. It can later call `socket.notify` to deliver
`socket.Info(msg)`.

```gleam
import beryl/socket

pub type Msg {
  JobFinished(String)
}

fn notify_socket(sender: socket.Sender(Msg), job_id: String) -> Nil {
  socket.notify(sender, JobFinished(job_id))
}
```

If the socket has already disconnected, `socket.notify` is ignored.

For long-lived external actors that should stream updates into a socket, see `beryl/bridge`.

## Effect order is observable order

The runtime applies effects in list order during one actor turn. Therefore:

```gleam
socket.Next(model, [
  socket.AcceptJoin(ref, None),
  socket.Push(topic_name, "ready", json.object([])),
])
```

The client sees the join acknowledgment first and the `ready` push second.

The same rule matters for replies:

- order `socket.Push` after the `socket.AcceptJoin` it depends on,
- order `socket.ReplyOk` / `socket.ReplyError` where you want them emitted.

## Next steps

- [WebSocket Transport](/guides/websocket/) — connect browsers and seed `ConnectInfo.seed.metadata`
- [Presence](/guides/presence/) — keep synchronous presence work outside the shared runtime
- [Runtime & Effect Interpreter](/architecture/runtime/) — runtime behavior, effect ordering, and teardown details
