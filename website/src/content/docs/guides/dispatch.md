---
title: App-Side Dispatch
description: Route joins, messages, binary frames, close events, and typed server messages in one update function.
---

Beryl's current programming model is **app-side dispatch**: you start one runtime with `beryl.start` (or `beryl.child_spec`), build a per-socket model in `init`, and route every socket event in one `update` function.

There is no registry to populate and no per-topic module lifecycle to wire up. Your application owns routing by matching on `event.Event` values and returning `event.Next(model, effects)`.

## The two app entry points

```gleam
import beryl
import beryl/event as event
import beryl/wire

let assert Ok(sockets) =
  beryl.start(
    beryl.config(wire.phoenix_codec()),
    init: init,
    update: update,
  )
```

- `init` runs once per socket connection and returns `#(model, List(event.Effect))`.
- `update` receives every `event.Event(msg)` for that socket and returns either:
  - `event.Next(model, effects)` to continue, or
  - `event.Stop(reason)` to close the whole socket.

`event.Event(msg)` is the whole contract:

- `event.Join(topic, payload, ref)`
- `event.Message(topic, event, payload, ref)`
- `event.Binary(topic, data)`
- `event.Closed(topic, reason)`
- `event.Info(msg)`

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
import beryl/event as event
import beryl/topic
import gleam/json
import gleam/list
import gleam/option.{Some}

pub type Msg {
  Tick(Int)
}

pub type Model {
  Model(joined_topics: List(String), self: event.Sender(Msg))
}

fn init(info: event.ConnectInfo(Msg)) -> #(Model, List(event.Effect)) {
  #(Model(joined_topics: [], self: info.self), [])
}

fn update(model: Model, ev: event.Event(Msg)) -> event.Next(Model, Msg) {
  let room_pattern = topic.parse_pattern("room:*")

  case ev {
    event.Join(topic_name, _payload, ref) ->
      case topic.extract_id(room_pattern, topic_name) {
        Ok(room_id) ->
          event.Next(
            Model(
              joined_topics: [topic_name, ..model.joined_topics],
              self: model.self,
            ),
            [
              event.AcceptJoin(
                ref,
                Some(json.object([
                  #("room_id", json.string(room_id)),
                ])),
              ),
              event.Push(
                topic_name,
                "system:joined",
                json.object([#("room_id", json.string(room_id))]),
              ),
            ],
          )

        Error(_) ->
          event.Next(
            model,
            [
              event.RejectJoin(
                ref,
                json.object([
                  #("reason", json.string("unknown topic")),
                ]),
              ),
            ],
          )
      }

    event.Message(_topic_name, "ping", _payload, Some(ref)) ->
      event.Next(
        model,
        [
          event.ReplyOk(
            ref,
            json.object([#("status", json.string("ok"))]),
          ),
        ],
      )

    event.Message(topic_name, "typing", _payload, _ref) ->
      event.Next(
        model,
        [event.BroadcastFrom(topic_name, "typing", json.object([]))],
      )

    event.Closed(topic_name, _reason) ->
      event.Next(
        Model(
          ..model,
          joined_topics: list.filter(model.joined_topics, fn(topic) {
            topic != topic_name
          }),
        ),
        [],
      )

    event.Info(Tick(at)) -> {
      let effects =
        list.map(model.joined_topics, fn(topic_name) {
          event.Push(
            topic_name,
            "tick",
            json.object([#("at", json.int(at))]),
          )
        })
      event.Next(model, effects)
    }

    event.Binary(_topic_name, _data) ->
      event.Next(model, [])

    event.Message(_, _, _, None) ->
      event.Next(model, [])
  }
}
```

A few important details:

- Joins are explicit: return `event.AcceptJoin(ref, reply)` or `event.RejectJoin(ref, reason)`.
- Message replies are explicit too: use `event.ReplyOk` / `event.ReplyError` when a client ref is present.
- `event.Closed(topic, reason)` replaces per-topic cleanup hooks. Prune topic-local state there.
- `event.Info(msg)` is just a typed message from your own server code.

## Routing many topics from one app

Multi-topic apps usually keep one top-level `Model` and delegate to smaller pure modules.

```gleam
import beryl/event as event
import beryl/topic
import gleam/json

pub type Model {
  Model(chat: chat.Model, admin: admin.Model)
}

pub type Msg {
  ChatMsg(chat.Msg)
  AdminMsg(admin.Msg)
}

fn update(model: Model, ev: event.Event(Msg)) -> event.Next(Model, Msg) {
  let chat_pattern = topic.parse_pattern("chat:*")
  let admin_pattern = topic.parse_pattern("admin")

  case ev {
    event.Join(topic_name, payload, ref) ->
      case topic.extract_id(chat_pattern, topic_name) {
        Ok(room_id) -> {
          let #(chat_model, effects) =
            chat.join(model.chat, room_id, payload, ref)
          event.Next(Model(..model, chat: chat_model), effects)
        }

        Error(_) ->
          case topic.matches(admin_pattern, topic_name) {
            True -> {
              let #(admin_model, effects) =
                admin.join(model.admin, payload, ref)
              event.Next(Model(..model, admin: admin_model), effects)
            }
            False ->
              event.Next(
                model,
                [
                  event.RejectJoin(
                    ref,
                    json.object([
                      #("reason", json.string("unknown topic")),
                    ]),
                  ),
                ],
              )
          }
      }

    event.Message(topic_name, event_name, payload, ref) ->
      case topic.extract_id(chat_pattern, topic_name) {
        Ok(room_id) -> {
          let #(chat_model, effects) =
            chat.on_message(model.chat, room_id, event_name, payload, ref)
          event.Next(Model(..model, chat: chat_model), effects)
        }
        Error(_) ->
          case topic.matches(admin_pattern, topic_name) {
            True -> {
              let #(admin_model, effects) =
                admin.on_message(model.admin, event_name, payload, ref)
              event.Next(Model(..model, admin: admin_model), effects)
            }
            False -> event.Next(model, [])
          }
      }

    event.Binary(topic_name, data) ->
      chat.on_binary(model, topic_name, data)

    event.Closed(topic_name, reason) ->
      chat.on_closed(model, topic_name, reason)

    event.Info(msg) ->
      chat.on_info(model, msg)
  }
}
```

The top-level `update` is the router. Smaller modules own their own sub-models and return ordinary `List(event.Effect)` values back to the parent.

## Typed server-side messages

`event.ConnectInfo.self` gives each socket a typed `event.Sender(msg)`. Any process can keep that sender and deliver `event.Info(msg)` later with `event.notify`.

```gleam
import beryl/event

pub type Msg {
  JobFinished(String)
}

fn notify_socket(sender: event.Sender(Msg), job_id: String) -> Nil {
  event.notify(sender, JobFinished(job_id))
}
```

If the socket has already disconnected, `event.notify` is ignored.

For long-lived external actors that should stream updates into a socket, see `beryl/bridge`.

## Effect order is observable order

The runtime applies effects strictly in list order inside one actor turn. That means this is guaranteed:

```gleam
event.Next(model, [
  event.AcceptJoin(ref, None),
  event.Push(topic_name, "ready", json.object([])),
])
```

The client sees the join acknowledgment first and the `ready` push second.

The same rule matters for presence and replies:

- order `event.Push` after the `event.AcceptJoin` it depends on,
- order `event.ReplyOk` / `event.ReplyError` where you want them emitted,
- order `event.PushPresence` / `event.BroadcastPresence` after the earlier presence changes they should reflect.

## Next steps

- [Coming from Phoenix](/guides/coming-from-phoenix/) — map channel modules, callbacks, and assigns onto this model
- [WebSocket Transport](/guides/websocket/) — connect browsers and seed `ConnectInfo.seed.metadata`
- [Presence](/guides/presence/) — use `PresenceTrack`, `PresenceUntrack`, and snapshot effects
- [Runtime & Effect Interpreter](/architecture/runtime/) — runtime behavior, effect ordering, and teardown details
