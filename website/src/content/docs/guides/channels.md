---
title: Sockets and Topics
---

Beryl delivers every WebSocket event to a single pair of functions your app
supplies to `beryl.child_spec`: `init`, which builds a per-socket **model**
when a client connects, and `update`, which receives every **event** for
that socket and returns the next model plus a list of **effects**. Your app
routes topics itself by pattern matching on the event's topic — there is no
handler registry and no per-topic callback modules.

```gleam
import beryl
import beryl/event.{type Event, type Next}
import beryl/wire
import gleam/otp/static_supervisor

pub fn main() {
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(initial_model(), []) },
      update: update,
    )
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  // Hand `sockets` to a transport (beryl_mist / beryl_ewe) and to any
  // code that broadcasts.
}
```

If you've used Elm or Lustre, this is the same architecture applied to a
socket: model in, event in, new model and effects out.

## Topics

Topics are colon-delimited string identifiers like `room:lobby` or
`document:tenant-a:doc-42`. Clients join topics with `phx_join`; your
`update` decides which joins to accept by matching on the topic string:

```gleam
case ev {
  event.Join("room:" <> room_id, payload, ref) -> // accept or reject
  event.Join("admin", payload, ref) -> // ...
  event.Join(_, _, ref) ->
    event.Next(model, [event.RejectJoin(ref, unknown_topic_error())])
  // ...
}
```

For topics with several dynamic segments, `beryl/topic` helps take them
apart:

```gleam
import beryl/topic

topic.segments("room:lobby")   // -> ["room", "lobby"]
topic.namespace("room:lobby")  // -> Ok("room")

// Extract multiple dynamic segments with a pattern
topic.extract_wildcards(
  topic.parse_pattern("document:*:*"),
  "document:tenant-a:doc-42",
)
// -> Ok(["tenant-a", "doc-42"])
```

## Events

`update` receives one of five events (`beryl/event.Event(msg)`):

| Event | When |
|-------|------|
| `Join(topic, payload, ref)` | Client asked to join a topic. Answer with `AcceptJoin` or `RejectJoin`. |
| `Message(topic, event, payload, ref)` | Client message on a joined topic. `ref` is `Some` when the client expects a reply. |
| `Binary(topic, data)` | Raw binary frame on a joined topic (codecs without a binary decoder). |
| `Closed(topic, reason)` | A joined topic ended — client leave, kick, heartbeat eviction, or socket close. |
| `Info(msg)` | Typed server-side message delivered through the socket's `Sender`. |

The `msg` parameter is your own type: whatever server-side processes send
to this socket arrives as `Info(msg)` with no casts and no `Dynamic`.

## Effects

One update may return several effects; they are applied in list order:

| Effect | Description |
|--------|-------------|
| `AcceptJoin(ref, reply)` | Accept a pending join, optionally with a reply payload |
| `RejectJoin(ref, reason)` | Reject a pending join with an error payload |
| `ReplyOk(ref, payload)` / `ReplyError(ref, payload)` | Answer a client message's ref with an ok/error `phx_reply` |
| `Push(topic, event, payload)` | Server-initiated message to this socket |
| `Broadcast(topic, event, payload)` | Message to every subscriber of a topic |
| `BroadcastFrom(topic, event, payload)` | Broadcast excluding this socket |
| `KickTopic(topic)` | Close this socket's subscription to a topic |

A `Join` left unanswered by the end of the update is rejected automatically
(fail closed), and `Push`/`Broadcast` to a topic whose join has not been
accepted yet are dropped. An `AcceptJoin` earlier in the list is guaranteed
to reach the wire before a `Push` later in the same list.

To end the whole socket instead of returning effects, return
`event.Stop(reason)`.

## A minimal topic app

A single-topic-namespace app needs no routing machinery — your model and
message types are used directly:

```gleam
import beryl
import beryl/event.{
  type Event, type Next, AcceptJoin, Broadcast, Join, Message, Next, ReplyOk,
}
import beryl/wire
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/static_supervisor

pub type Model {
  Model(username: String, joined: Bool)
}

pub fn main() {
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Model(username: "anonymous", joined: False), []) },
      update: update,
    )
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  // ... wire up the transport
}

fn update(model: Model, ev: Event(Nil)) -> Next(Model, Nil) {
  case ev {
    Join("room:" <> _, payload, ref) -> {
      let username = decode_username(payload)
      Next(Model(username: username, joined: True), [
        AcceptJoin(ref, Some(json.object([#("status", json.string("joined"))]))),
      ])
    }
    Join(_, _, ref) ->
      Next(model, [
        event.RejectJoin(
          ref,
          json.object([#("reason", json.string("unknown_topic"))]),
        ),
      ])

    Message(topic, "new_message", payload, Some(ref)) ->
      Next(model, [
        ReplyOk(ref, json.object([#("ok", json.bool(True))])),
        Broadcast(topic, "new_message", relay(payload, model.username)),
      ])
    Message(_, "typing", _, _) ->
      // No reply needed
      Next(model, [])

    event.Closed(_topic, _reason) ->
      // Clean up anything this topic owned
      Next(Model(..model, joined: False), [])

    _ -> Next(model, [])
  }
}
```

Note how state threading is just the model: no socket handle, no assigns
API — the value you return is the value the next event sees.

## Routing multiple topic namespaces

Apps that serve several kinds of topics keep one sub-model per joined topic
and route by prefix. The conventional shape is a `Dict` per namespace,
pruned on `Closed`:

```gleam
import gleam/dict.{type Dict}

type Model {
  Model(socket_id: String, rooms: Dict(String, chat.Model))
}

fn update(ctx: chat.Ctx, model: Model, ev: Event(Msg)) -> Next(Model, Msg) {
  case ev {
    event.Join(topic, payload, ref) ->
      case topic {
        "room:" <> _ -> {
          let #(joined, effects) =
            chat.join(ctx, model.socket_id, topic, payload, ref)
          event.Next(store(model, topic, joined), effects)
        }
        _ -> event.Next(model, [event.RejectJoin(ref, unknown_topic())])
      }

    event.Message(topic, event_name, payload, ref) ->
      case dict.get(model.rooms, topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            chat.update(ctx, model.socket_id, topic, sub, event_name, payload, ref)
          event.Next(store(model, topic, Some(sub)), effects)
        }
        Error(Nil) -> event.Next(model, [])
      }

    event.Closed(topic, _reason) ->
      case dict.get(model.rooms, topic) {
        Ok(sub) ->
          event.Next(
            Model(..model, rooms: dict.delete(model.rooms, topic)),
            chat.closed(ctx, model.socket_id, topic, sub),
          )
        Error(Nil) -> event.Next(model, [])
      }

    _ -> event.Next(model, [])
  }
}
```

Here `chat` is an **embeddable app**: a module exporting a topic-scoped
`Model`, a `join`/`update`/`closed` triple, and its own `Ctx` of
dependencies. This is the Elm/Lustre composition pattern — third-party
functionality ships as such triples and apps wire them in exactly like
their own namespaces. The repository's `examples/showcase` composes three
embeddable apps (chat rooms, live cursors, collaborative documents) on one
socket this way.

## Connect-time data

`init` receives a `ConnectInfo(msg)` with everything known at connect
time:

```gleam
init: fn(info: event.ConnectInfo(Msg)) {
  // info.socket_id — unique id for this socket
  // info.seed      — request path, query params, and headers from the upgrade
  // info.self      — typed Sender for server-side messages (see below)
  let token = list.key_find(info.seed.query, "token")
  #(build_model(info.socket_id, token), [])
}
```

The `seed` replaces connect-time "assigns": the transport gathers the
upgrade request's path, query, and headers, and your `init` turns them into
whatever model state it wants. Transport-level `on_connect` hooks remain
available as pure auth gates that can reject the upgrade before any join —
see [WebSocket Transport → Authentication](/guides/websocket#authentication).

## Server-side messages

Any process can push typed messages into a socket through the `Sender`
handed to `init`:

```gleam
type Msg {
  Tick(at: Int)
  Notify(text: String)
}

init: fn(info: event.ConnectInfo(Msg)) {
  // Hand info.self to whatever server-side process needs to reach this
  // socket — a timer, a DB listener, a job runner.
  start_ticker(info.self)
  #(initial_model(), [])
}

// Elsewhere, in the ticker process:
event.notify(sender, Tick(now_ms))
```

The message arrives in `update` as `Info(Tick(at))` — an ordinary typed
send with exhaustive pattern matching, no `Dynamic`, and no registry
lookup. If the socket has disconnected, `notify` is a quiet no-op.

For timers and background jobs, spawn the process in `init` (or on join)
and stop it when you see `Closed` for the owning topic or when the model is
torn down.

## Broadcasting from outside update

Code that holds the `Sockets` handle can broadcast without going through
`update`:

```gleam
// Broadcast to everyone on a topic
beryl.broadcast(
  sockets,
  "room:lobby",
  "new_message",
  json.object([#("text", json.string("Hello!"))]),
)

// Broadcast to everyone except one socket
beryl.broadcast_from(
  sockets,
  socket_id,
  "room:lobby",
  "user_typing",
  json.object([#("user", json.string("alice"))]),
)
```

Inside `update`, prefer the `Broadcast`/`BroadcastFrom` effects — they are
ordered relative to the other effects in the same list.

## Next steps

- [Reference](/reference/) — module map, wire protocol details, and the broadcast/push cheatsheet
- [Presence guide](/guides/presence/) — track who is online and broadcast presence diffs to clients
- [Groups guide](/guides/groups/) — broadcast a single event to multiple topics at once
- [PubSub guide](/guides/pubsub/) — distributed messaging for multi-node deployments
- [Error Handling guide](/guides/error-handling/) — rejected joins, rate limits, and client-visible error shapes
