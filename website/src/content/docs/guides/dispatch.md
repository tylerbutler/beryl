---
title: App-Side Dispatch
description: Route joins, messages, binary frames, close events, and typed server messages in one update function.
---

Beryl's current programming model is **app-side dispatch**: you start one runtime with `beryl.start` (or `beryl.child_spec`), build a per-socket model in `init`, and route every socket event in one `update` function.

There is no registry to populate and no per-topic module lifecycle to wire up. Your application owns routing by matching on `socket.Input` values and returning `socket.Next(model, effects)`.

## The two app entry points

```gleam
import beryl
import beryl/socket
import beryl/wire

let assert Ok(sockets) =
  beryl.start(
    beryl.config(wire.phoenix_codec()),
    init: init,
    update: update,
  )
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

For a single namespace it is fine to match patterns yourself inside `update`, as the next example does. Once several namespaces share one socket, reach for `beryl/socket/router` instead of hand-rolling the dispatch — see [Routing many topics from one app](#routing-many-topics-from-one-app).

## Single-topic example

This example accepts `room:*` joins, replies to `ping`, broadcasts `typing` to everyone except the sender, tracks joined topics in the model, and reacts to typed server-side `Info` messages.

```gleam
import beryl/socket
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

Multi-topic apps keep one top-level `Model` and delegate to smaller pure modules. `beryl/socket/router` supplies the dispatch: register one `Namespace` per topic pattern, and `router.route` hands each input to the first namespace whose pattern matches its topic.

```gleam
import beryl/socket
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
      put: fn(model: Model, rooms) { Model(..model, rooms:) },
      join: chat.join,
      message: chat.on_message,
      closed: chat.on_closed,
    ),
    router.stateful(
      pattern: "document:*:*",
      socket_id: fn(model: Model) { model.socket_id },
      get: fn(model: Model) { model.docs },
      put: fn(model: Model, docs) { Model(..model, docs:) },
      join: fn(socket_id, match, payload, ref) {
        docs.join(ctx, socket_id, match, payload, ref)
      },
      message: fn(socket_id, match, doc, event, payload, ref) {
        docs.on_message(ctx, socket_id, match, doc, event, payload, ref)
      },
      closed: fn(_socket_id, _match, _doc) { [] },
    ),
  ]
  fn(model, ev) { router.route(namespaces, router.unknown_topic(), model, ev) }
}
```

Build the namespace list once in a factory like this and return the closure, rather than rebuilding it on every delivered input.

Patterns use the same `beryl/topic` syntax as `beryl.with_topic_rate`, and handlers receive a `router.Match` carrying the concrete topic plus the values the pattern's wildcards captured — `match.params` is `["general"]` for `"room:*"` matching `"room:general"`, or `["acme", "readme"]` for `"document:*:*"` matching `"document:acme:readme"` — so handlers never re-split topic strings.

Routing fails closed: a `Join` for a topic no namespace claims is rejected with the payload you pass (`router.unknown_topic()` is the conventional one), other unclaimed inputs are ignored, and `Binary`/`Info` pass through as `socket.Next(model, [])` for you to handle after `route` if you need them.

Each constructor covers one shape:

- `router.stateful` — per-topic state in a `Dict` keyed by topic inside your model; `socket_id`/`get`/`put` project the model onto the pieces the namespace owns, and a join returning `None` leaves no state behind.
- `router.accept_only` — read-only topics that accept joins and carry no state.
- `router.namespace` — full control: handlers take and return the whole socket-wide model.

For a standalone server built around one stateful namespace, `router.Standalone` is the canonical model — pair `router.standalone_init` with `beryl.start` and adapt a projection-taking namespace factory with `router.standalone_namespace`. The [example apps](/examples/) use exactly this shape.

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

The same rule matters for presence and replies:

- order `socket.Push` after the `socket.AcceptJoin` it depends on,
- order `socket.ReplyOk` / `socket.ReplyError` where you want them emitted,
- order `socket.PushPresence` / `socket.BroadcastPresence` after the earlier presence changes they should reflect.

## Next steps

- [Coming from Phoenix](/guides/coming-from-phoenix/) — map channel modules, callbacks, and assigns onto this model
- [WebSocket Transport](/guides/websocket/) — connect browsers and seed `ConnectInfo.seed.metadata`
- [Presence](/guides/presence/) — use `PresenceTrack`, `PresenceUntrack`, and snapshot effects
- [Runtime & Effect Interpreter](/architecture/runtime/) — runtime behavior, effect ordering, and teardown details
