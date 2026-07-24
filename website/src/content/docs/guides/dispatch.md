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

Keep the topic pattern in your own routing function, then decide which branch owns the event.

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

Multi-topic apps usually keep one top-level `Model` and delegate to smaller pure modules.

```gleam
import beryl/socket
import beryl/topic
import gleam/json

pub type Model {
  Model(chat: chat.Model, admin: admin.Model)
}

pub type Msg {
  ChatMsg(chat.Msg)
  AdminMsg(admin.Msg)
}

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model, Msg) {
  let chat_pattern = topic.parse_pattern("chat:*")
  let admin_pattern = topic.parse_pattern("admin")

  case ev {
    socket.Join(topic_name, payload, ref) ->
      case topic.extract_id(chat_pattern, topic_name) {
        Ok(room_id) -> {
          let #(chat_model, effects) =
            chat.join(model.chat, room_id, payload, ref)
          socket.Next(Model(..model, chat: chat_model), effects)
        }

        Error(_) ->
          case topic.matches(admin_pattern, topic_name) {
            True -> {
              let #(admin_model, effects) =
                admin.join(model.admin, payload, ref)
              socket.Next(Model(..model, admin: admin_model), effects)
            }
            False ->
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
      }

    socket.Message(topic_name, event_name, payload, ref) ->
      case topic.extract_id(chat_pattern, topic_name) {
        Ok(room_id) -> {
          let #(chat_model, effects) =
            chat.on_message(model.chat, room_id, event_name, payload, ref)
          socket.Next(Model(..model, chat: chat_model), effects)
        }
        Error(_) ->
          case topic.matches(admin_pattern, topic_name) {
            True -> {
              let #(admin_model, effects) =
                admin.on_message(model.admin, event_name, payload, ref)
              socket.Next(Model(..model, admin: admin_model), effects)
            }
            False -> socket.Next(model, [])
          }
      }

    socket.Binary(topic_name, data) ->
      chat.on_binary(model, topic_name, data)

    socket.Closed(topic_name, reason) ->
      chat.on_closed(model, topic_name, reason)

    socket.Info(msg) ->
      chat.on_info(model, msg)
  }
}
```

The top-level `update` is the router. Smaller modules own their own sub-models and return ordinary `List(socket.Effect)` values back to the parent.

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
