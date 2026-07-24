---
title: Coming from Phoenix
description: Map Phoenix Channels concepts — channel modules, join/handle_in/handle_info, assigns, Presence — onto beryl's app-side dispatch model.
---

beryl speaks the same wire protocol as Phoenix Channels (`phx_join`, refs,
heartbeats, `presence_state`/`presence_diff`), so Phoenix client libraries
work unchanged. The server-side programming model is different, and this page
maps one onto the other.

## The core difference: who owns the router

In Phoenix, **the framework owns the router**. You declare a routing table in
your socket module (`channel "room:*", RoomChannel`), Phoenix spawns one
channel process per joined topic, and it calls your callbacks
(`join`, `handle_in`, `handle_info`, `terminate`) with per-channel state in
`socket.assigns`.

In beryl, **your app owns the router**. There is no registry and no channel
module: you pass one `init` and one `update` function to `beryl.start`, and
every event for a socket — joins, messages, closes, server-side messages,
across all of its topics — arrives at that `update` as an `event.Event(msg)`
value. You route topics yourself with pattern matching, and per-socket state
lives in one `model` you return from each `update`.

Everything below the programming model works the way you expect from Phoenix:
colon-delimited topics with wildcard patterns, CRDT-backed presence, pg-backed
PubSub, heartbeats, and the JSON array wire format.

## Concept map

| Phoenix | beryl |
| ------- | ----- |
| `socket "/socket", UserSocket` in the Endpoint | `beryl_mist.handler` / `beryl_ewe` mounted on your HTTP server |
| `UserSocket.connect(params, socket)` | `init(info)` — request data in `info.seed` (path, query, headers, metadata) |
| `channel "room:*", RoomChannel` routing table | topic pattern match in `update`, with `beryl/topic` helpers |
| One channel process per joined topic | One `model` + `update` per socket, covering all its joined topics |
| `socket.assigns` + `assign/3` | your `model`, returned from each `update` |
| `join/3` callback | `event.Join(topic, payload, ref)` |
| `{:ok, socket}` / `{:ok, reply, socket}` | `event.AcceptJoin(ref, None)` / `event.AcceptJoin(ref, Some(reply))` |
| `{:error, %{reason: ...}}` | `event.RejectJoin(ref, reason)` |
| `handle_in/3` | `event.Message(topic, event, payload, ref)` |
| `{:reply, {:ok, payload}, socket}` | `event.ReplyOk(ref, payload)` / `event.ReplyError(ref, payload)` |
| `{:noreply, socket}` | `event.Next(model, [])` |
| `socket_ref/1` + `Phoenix.Channel.reply/2` (reply later) | store the `Ref` in your model, `event.ReplyOk` from a later `update` turn |
| `push(socket, event, payload)` | `event.Push(topic, event, payload)` effect |
| `broadcast!/3` | `event.Broadcast(topic, event, payload)` effect |
| `broadcast_from!/3` | `event.BroadcastFrom(topic, event, payload)` effect |
| `handle_info(msg, socket)` + `send(pid, msg)` | `event.Info(msg)` + `event.notify(sender, msg)` — typed end to end |
| `terminate/2` | `event.Closed(topic, reason)` event, delivered on every exit path |
| `{:stop, reason, socket}` (ends one channel) | `event.KickTopic(topic)` for one topic, `event.Stop(reason)` for the whole socket |
| `MyAppWeb.Endpoint.broadcast/3` from anywhere | `beryl.broadcast(sockets, topic, event, payload)` |
| `Phoenix.PubSub` | `beryl/pubsub`, also built on `pg` |
| `Phoenix.Presence.track/3` / `untrack/3` | `event.PresenceTrack(topic, key, meta)` / `event.PresenceUntrack(topic, key)` effects |
| `push(socket, "presence_state", Presence.list(socket))` | `event.PushPresence(topic, "presence_state", presence_wire.encode_state)` |
| `intercept` / `handle_out` | no equivalent — shape payloads before `Broadcast`, or per-socket with `Push` |

## Side by side: a room channel

The same channel in both models. Phoenix first:

```elixir
defmodule MyAppWeb.RoomChannel do
  use Phoenix.Channel

  def join("room:" <> room_id, _payload, socket) do
    {:ok, %{room_id: room_id}, assign(socket, :room_id, room_id)}
  end

  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{status: "ok"}}, socket}
  end

  def handle_in("typing", _payload, socket) do
    broadcast_from!(socket, "typing", %{})
    {:noreply, socket}
  end

  def handle_info({:tick, at}, socket) do
    push(socket, "tick", %{at: at})
    {:noreply, socket}
  end
end
```

The beryl equivalent — the callbacks become arms of one `case` expression, and
the imperative `push`/`broadcast_from!` calls become effect values returned to
the runtime:

```gleam
import beryl/event
import gleam/json
import gleam/option.{Some}

pub type Msg {
  Tick(Int)
}

pub type Model {
  Model(room_id: String)
}

fn init(_info: event.ConnectInfo(Msg)) -> #(Model, List(event.Effect)) {
  #(Model(room_id: ""), [])
}

fn update(model: Model, ev: event.Event(Msg)) -> event.Next(Model, Msg) {
  case ev {
    event.Join("room:" <> room_id, _payload, ref) ->
      event.Next(Model(room_id: room_id), [
        event.AcceptJoin(
          ref,
          Some(json.object([#("room_id", json.string(room_id))])),
        ),
      ])

    event.Message(_topic, "ping", _payload, Some(ref)) ->
      event.Next(model, [
        event.ReplyOk(ref, json.object([#("status", json.string("ok"))])),
      ])

    event.Message(topic, "typing", _payload, _ref) ->
      event.Next(model, [
        event.BroadcastFrom(topic, "typing", json.object([])),
      ])

    event.Info(Tick(at)) ->
      event.Next(model, [
        event.Push(
          "room:" <> model.room_id,
          "tick",
          json.object([#("at", json.int(at))]),
        ),
      ])

    _ -> event.Next(model, [])
  }
}
```

Three shifts to notice:

- **Side effects are values.** Phoenix callbacks call `push` and
  `broadcast_from!` imperatively; a beryl `update` returns a list of effects
  and the runtime applies them, strictly in list order, after the turn ends.
  List order is wire order, so `[AcceptJoin(ref, None), Push(topic, "ready", ..)]`
  guarantees the client sees the join ack before the push.
- **Join acks are explicit and fail closed.** Phoenix infers the ack from
  `join/3`'s return value. In beryl you answer the `Join` event with
  `AcceptJoin` or `RejectJoin`; a join left unanswered by the end of the
  `update` turn is rejected automatically.
- **Server-side messages are typed.** Phoenix's `handle_info` receives any
  term; beryl's `Info(msg)` carries your own `msg` type, delivered through the
  typed `event.Sender(msg)` from `ConnectInfo.self` — the compiler checks
  every variant.

## One process per topic vs. one model per socket

The biggest structural change is granularity. A Phoenix client joined to
`room:1` and `room:2` runs two channel processes, each with its own assigns.
The same client in beryl has **one** model, and `update` sees events for both
topics tagged with their topic string.

For a single channel type this is simpler: your types go straight into the
model, no wrapper needed. When one app serves several channel types, your
model holds each sub-state and your `update` delegates — the parent-routes-to-
children pattern from Elm and Lustre:

```gleam
pub type Model {
  Model(chat: chat.Model, admin: admin.Model)
}

pub type Msg {
  ChatMsg(chat.Msg)
  AdminMsg(admin.Msg)
}
```

See [Routing many topics from one app](/guides/dispatch/#routing-many-topics-from-one-app)
for the full pattern.

Crash blast radius matches this granularity and still ends at the socket: a
crashing `update` takes down that socket's model and its joined topics, and
does not affect other sockets.

## Presence

The common Phoenix `:after_join` dance —

```elixir
def handle_info(:after_join, socket) do
  {:ok, _} = Presence.track(socket, socket.assigns.user_id, %{status: "online"})
  push(socket, "presence_state", Presence.list(socket))
  {:noreply, socket}
end
```

— collapses into the `Join` arm, because effect ordering makes "ack first,
then track, then send the snapshot" a single list:

```gleam
event.Join(topic_name, _payload, ref) ->
  event.Next(model, [
    event.AcceptJoin(ref, None),
    event.PresenceTrack(
      topic_name,
      "user:" <> model.user_id,
      json.object([#("status", json.string("online"))]),
    ),
    event.PushPresence(topic_name, "presence_state", presence_wire.encode_state),
  ])
```

`PushPresence` and `BroadcastPresence` read presence state when the effect is
applied, so the snapshot already includes the `PresenceTrack` earlier in the
same list. The wire payloads (`presence_state`, `presence_diff`) match Phoenix
Presence's shapes. See the [Presence guide](/guides/presence/) for setup and
cross-node replication.

## Broadcasting from outside a socket

Where you would call `MyAppWeb.Endpoint.broadcast("room:lobby", "notice", %{})`
from a controller or background job, call `beryl.broadcast` with the `Sockets`
handle returned by `beryl.start`:

```gleam
beryl.broadcast(sockets, "room:lobby", "notice", json.object([]))
```

With PubSub configured, `beryl.broadcast` distributes across the cluster, the
same way `Endpoint.broadcast` rides `Phoenix.PubSub`. To message one specific
socket (Phoenix: `send(channel_pid, msg)`), keep its `event.Sender(msg)` from
`ConnectInfo.self` and call `event.notify` — the message arrives as a typed
`Info` event.

## Next steps

- [App-Side Dispatch](/guides/dispatch/) — the full routing model, topic helpers, and effect ordering
- [WebSocket Transport](/guides/websocket/) — mount beryl on Mist or Ewe, Phoenix-compatible framing
- [Presence](/guides/presence/) — tracking, snapshots, and cross-node sync
- [PubSub](/guides/pubsub/) — the `pg`-backed publish/subscribe layer
