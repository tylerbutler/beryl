---
title: App-Side Dispatch
description: Route joins, messages, binary frames, close events, and typed server messages in one update function.
---

Beryl's current programming model is **app-side dispatch**: build one supervised runtime with `beryl.child_spec`, build a per-socket model in `init`, and route every socket event in one `update` function.

There is no registry to populate and no per-topic module lifecycle to wire up. Your application owns routing by matching on `socket.Input` values and returning `socket.Next(model, effects)`.

## The two app entry points

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

Topics are still colon-delimited strings, and `beryl/topic` is still the routing helper to reach for inside `update`.

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

For one namespace, matching inside `update` is fine. When several namespaces share a socket, use `beryl/socket/router` so pattern ownership and fail-closed dispatch stay declarative.

## Single-topic example

This example accepts `room:*` joins, replies to `ping`, broadcasts `typing` to everyone except the sender, tracks joined topics in the model, and reacts to typed server-side `Info` messages.

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

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model, Msg) {
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

Multi-topic apps keep one top-level model and register one `router.Namespace`
per topic pattern. The router sends each input to the first matching namespace.

```gleam
import beryl/socket as socket
import beryl/socket/router
import gleam/dict.{type Dict}

pub type Model {
  Model(
    socket_id: String,
    rooms: Dict(String, chat.Model),
    docs: Dict(String, docs.Model),
  )
}

fn update(ctx: Ctx) -> fn(Model, socket.Input(Msg)) -> socket.Next(Model, Msg) {
  let namespaces = [
    router.accept_only("lobby"),
    router.stateful(
      pattern: "room:*",
      socket_id: fn(model: Model) { model.socket_id },
      get: fn(model: Model) { model.rooms },
      put: fn(model: Model, rooms) { Model(..model, rooms: rooms) },
      join: chat.join,
      message: chat.on_message,
      closed: chat.on_closed,
    ),
    router.stateful(
      pattern: "document:*:*",
      socket_id: fn(model: Model) { model.socket_id },
      get: fn(model: Model) { model.docs },
      put: fn(model: Model, docs) { Model(..model, docs: docs) },
      join: fn(socket_id, match, payload, ref) {
        docs.join(ctx, socket_id, match, payload, ref)
      },
      message: fn(socket_id, match, doc, event, payload, ref) {
        docs.on_message(ctx, socket_id, match, doc, event, payload, ref)
      },
      closed: fn(_socket_id, _match, _doc) { [] },
    ),
  ]
  fn(model, input) {
    router.route(namespaces, router.unknown_topic(), model, input)
  }
}
```

Build the namespace list once in a factory like this rather than rebuilding it
for every input. Patterns use the same syntax as `beryl.with_topic_rate`, and
handlers receive `router.Match(topic:, params:)` with wildcard captures.

Routing fails closed: unclaimed joins are rejected with the supplied payload,
other unclaimed inputs are ignored, and `Binary`/`Info` pass through unchanged.
Use `router.stateful` for per-topic `Dict` state, `router.accept_only` for
read-only topics, or `router.namespace` for full model control.

For a standalone server around one stateful namespace, pair
`router.standalone_init` with `beryl.child_spec` and adapt the namespace with
`router.standalone_namespace`.

## Typed server-side messages

`socket.ConnectInfo.self` gives each socket a typed `socket.Sender(msg)`. Any process can keep that sender and deliver `socket.Info(msg)` later with `socket.notify`.

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

The runtime applies effects strictly in list order inside one actor turn. That means this is guaranteed:

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
