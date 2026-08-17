---
title: App-Side Dispatch
description: Route joins, messages, binary frames, close events, and typed server messages in one update function.
---

Raw **app-side dispatch** is beryl's core programming model: build one
supervised runtime with `beryl.child_spec`, build a per-socket model in
`init`, and route every socket event in one `update` function. For
multi-channel or Phoenix-shaped apps, the recommended
[`beryl_channels` layer](/guides/channels/) supplies this router for you.

There is no registry to populate and no per-topic module lifecycle to wire up. Your application owns routing by matching on `socket.Input` values and returning `socket.Next(model, effects)`.

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

For one namespace, matching inside `update` is fine, and `beryl/socket/router` keeps pattern ownership and fail-closed dispatch declarative. When several namespaces share a socket, use [`beryl_channels`](/guides/channels/) instead — see [Routing many topics from one app](#routing-many-topics-from-one-app).

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

Use [`beryl_channels`](/guides/channels/). Register a list of channel handlers
and the layer routes every socket event to the channel that owns its topic.
Each channel keeps its own private state and server-side message type, so
channels that share no types compose in one list, and there is no socket-wide
model, message union, or `update` function to write.

`beryl/socket/router` is the alternative when you want `beryl.child_spec` and
your own `update` with no additional dependency — typically a server around a
single topic namespace. Every namespace on a socket shares one model type, and
the app owns how per-topic state is stored in it:

```gleam
import beryl/socket as socket
import beryl/socket/router
import gleam/dict.{type Dict}
import gleam/option.{None, Some}

pub type Model {
  Model(socket_id: String, rooms: Dict(String, chat.Model))
}

fn rooms(ctx: Ctx) -> router.Namespace(Model) {
  router.namespace(
    pattern: "room:*",
    join: fn(model: Model, match: router.Match, payload, ref) {
      // Commit the room's state only when the join is accepted.
      case chat.join(ctx, model.socket_id, match, payload, ref) {
        #(Some(room), effects) -> #(
          Model(..model, rooms: dict.insert(model.rooms, match.topic, room)),
          effects,
        )
        #(None, effects) -> #(model, effects)
      }
    },
    message: fn(model: Model, match: router.Match, event, payload, ref) {
      case dict.get(model.rooms, match.topic) {
        Ok(room) -> {
          let #(room, effects) =
            chat.on_message(ctx, match.topic, room, event, payload, ref)
          #(
            Model(..model, rooms: dict.insert(model.rooms, match.topic, room)),
            effects,
          )
        }
        Error(Nil) -> #(model, [])
      }
    },
    closed: fn(model: Model, match: router.Match, reason) {
      case dict.get(model.rooms, match.topic) {
        Ok(room) -> #(
          Model(..model, rooms: dict.delete(model.rooms, match.topic)),
          chat.on_closed(ctx, match.topic, room, reason),
        )
        Error(Nil) -> #(model, [])
      }
    },
  )
}

fn update(ctx: Ctx) -> fn(Model, socket.Input(Msg)) -> socket.Next(Model) {
  let namespaces = [router.accept_only("lobby"), rooms(ctx)]
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
Use `router.accept_only` for read-only topics and `router.namespace` for topics
that carry state. Close handlers receive `socket.StopReason`, so normal closes,
shutdown, heartbeat timeouts, and crashes can be handled differently.

The `cursors` example is the smallest complete server written this way; the
`showcase` example is the same three topic namespaces composed with
`beryl_channels`.

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
