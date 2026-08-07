---
title: Coming from Phoenix
description: Map Phoenix Channels concepts — channel modules, join/handle_in/handle_info, assigns, Presence — onto beryl's channel layer and its dispatch core.
---

beryl speaks the same wire protocol as Phoenix Channels (`phx_join`, refs,
heartbeats, `presence_state`/`presence_diff`), so Phoenix client libraries
work unchanged. The server-side programming model is different, and this page
maps one onto the other.

beryl gives you two layers, and Phoenix maps onto both:

- **`beryl_channels`, the channel layer** — the close analogue, and the
  recommended default for a Phoenix-shaped app. You register a handler per
  topic pattern, and each channel gets colocated callbacks plus its own
  private state.
- **`beryl`, raw app-side dispatch** — the core underneath. One `init`/`update`
  pair per socket; you own the router.

[Choose an API](/choosing-an-api/) has the decision in one table. Everything
below the programming model works the way you expect from Phoenix:
colon-delimited topics with wildcard patterns, CRDT-backed presence, pg-backed
PubSub, heartbeats, and the JSON array wire format.

## The core difference: processes and state

In Phoenix, the framework owns the router *and* the process tree. You declare a
routing table in your socket module (`channel "room:*", RoomChannel`), Phoenix
spawns **one channel process per joined topic**, and it calls your callbacks
(`join`, `handle_in`, `handle_info`, `terminate`) with per-channel state in
`socket.assigns` — a map of atoms to untyped terms.

beryl keeps the routing table idea and drops the process-per-topic idea. With
the channel layer you declare handlers and get colocated callbacks with
per-topic state, but every channel on a socket runs sequentially inside that
socket's runtime actor, and its state is a **value of your own type**, not an
assigns map. With raw dispatch there is no routing table at all: every event
for a socket arrives at one `update` as a `socket.Input(msg)` value, and
per-socket state lives in one `model`.

Two practical consequences either way:

- **Long or blocking work belongs in your own process.** A slow callback holds
  up the socket. Hand results back with `channel.notify` (layer) or
  `socket.notify` (core).
- **Crash scope depends on the callback.** A join panic rejects that join;
  message/binary panics close that topic; an `on_info` panic ends the socket;
  and a terminate panic loses that callback's actions while core teardown
  continues. See [crash behavior](/guides/channels/#crash-behavior).

## Concept map

| Phoenix | beryl channel layer (`beryl_channels`) | beryl raw dispatch (`beryl`) |
| --- | --- | --- |
| `socket "/socket", UserSocket` in the Endpoint | `beryl_mist` / `beryl_ewe` mounted on your HTTP server | same |
| `UserSocket.connect(params, socket)` | transport `on_connect`; request data reaches `join` as `info.seed` | `init(info)` — request data in `info.seed` |
| `channel "room:*", RoomChannel` routing table | the handler list passed to `beryl_channels.child_spec` | topic pattern match in `update`, with `beryl/topic` helpers |
| One channel process per joined topic | one private state value per joined topic, in the socket's runtime actor | one `model` per socket, covering all its topics |
| `socket.assigns` + `assign/3` | the channel's own `state` type, returned from each callback | your `model`, returned from each `update` |
| `join/3` callback | the handler's `join` callback | `socket.Join(topic, payload, ref)` |
| `{:ok, socket}` / `{:ok, reply, socket}` | `channel.accept(..)` / `channel.accept_with(.., reply)` | `socket.AcceptJoin(ref, None)` / `socket.AcceptJoin(ref, Some(reply))` |
| `{:error, %{reason: ...}}` | `channel.reject(reason)` | `socket.RejectJoin(ref, reason)` |
| `handle_in/3` | `channel.on_message` | `socket.Message(topic, event, payload, ref)` |
| `{:reply, {:ok, payload}, socket}` | `channel.reply_ok(ref, payload)` / `channel.reply_error(ref, payload)` action | `socket.ReplyOk(ref, payload)` / `socket.ReplyError(ref, payload)` |
| `{:noreply, socket}` | `channel.continue(state)` | `socket.Next(model, [])` |
| `socket_ref/1` + `Phoenix.Channel.reply/2` (reply later) | keep the `Ref` in the channel's state, `reply_ok` from a later callback (not from `on_terminate` — see below) | store the `Ref` in your model, `socket.ReplyOk` from a later `update` turn |
| `push(socket, event, payload)` | `channel.push(event, payload)` action | `socket.Push(topic, event, payload)` effect |
| `broadcast!/3` | `channel.broadcast(event, payload)` action | `socket.Broadcast(topic, event, payload)` effect |
| `broadcast_from!/3` | `channel.broadcast_from(event, payload)` action | `socket.BroadcastFrom(topic, event, payload)` effect |
| `handle_info(msg, socket)` + `send(pid, msg)` | `channel.on_info` + `channel.notify(sender, msg)` — typed per channel | `socket.Info(msg)` + `socket.notify(sender, msg)` — typed per socket |
| `:after_join` self-send | `channel.with_actions` on the accepted join (ordered immediately after the ack) | order the effects after `AcceptJoin` in the same list |
| `terminate/2` | `channel.on_terminate`, which returns actions | `socket.Closed(topic, reason)` event, delivered on every exit path |
| `{:stop, reason, socket}` (ends one channel) | `channel.close()` / `channel.close_with(actions)` | `socket.KickTopic(topic)` |
| ending the whole socket | `channel.stop_socket(reason)` | `socket.Stop(reason)` |
| `MyAppWeb.Endpoint.broadcast/3` from anywhere | `beryl.broadcast(sockets, topic, event, payload)` | same |
| `Phoenix.PubSub` | `beryl/pubsub`, also built on `pg` | same |
| `Phoenix.Presence.track/3` / `untrack/3` | `channel.presence_track(key, meta)` / `channel.presence_untrack(key)` actions | `socket.PresenceTrack(topic, key, meta)` / `socket.PresenceUntrack(topic, key)` effects |
| `push(socket, "presence_state", Presence.list(socket))` | `channel.push_presence("presence_state", presence_wire.encode_state)` | `socket.PushPresence(topic, "presence_state", presence_wire.encode_state)` |
| `intercept` / `handle_out` | no equivalent — shape payloads before `broadcast`, or per-socket with `push` | no equivalent — same advice |

## Side by side: a room channel

The same channel in all three models. Phoenix first:

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

The channel layer keeps the shape — one module per channel, colocated
callbacks, per-topic state — and turns the imperative `push`/`broadcast_from!`
calls into ordered action values:

```gleam
import beryl_channels/channel
import gleam/json
import gleam/option.{Some}

type State {
  State(room_id: String)
}

pub type Note {
  Tick(Int)
}

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(_info: channel.JoinInfo(Note), topic, _payload) {
    channel.accept_with(
      channel.joined(State(room_id: topic), callbacks()),
      json.object([#("room_id", json.string(topic))]),
    )
  })
}

fn callbacks() -> channel.Callbacks(State, Note) {
  channel.callbacks()
  |> channel.on_message(fn(state: State, message: channel.Message) {
    case message.event, message.reply {
      "ping", Some(ref) ->
        channel.continue_with(
          state,
          channel.actions()
            |> channel.reply_ok(
              ref,
              json.object([#("status", json.string("ok"))]),
            ),
        )

      "typing", _ ->
        channel.continue_with(
          state,
          channel.actions() |> channel.broadcast_from("typing", json.object([])),
        )

      _, _ -> channel.continue(state)
    }
  })
  |> channel.on_info(fn(state: State, note: Note) {
    let Tick(at) = note
    channel.continue_with(
      state,
      channel.actions()
        |> channel.push("tick", json.object([#("at", json.int(at))])),
    )
  })
}
```

Raw dispatch flattens the same behavior into arms of one `case`, and names the
topic on every effect:

```gleam
import beryl/socket
import gleam/json
import gleam/option.{Some}

pub type Msg {
  Tick(Int)
}

pub type Model {
  Model(room_id: String)
}

fn init(_info: socket.ConnectInfo(Msg)) -> #(Model, List(socket.Effect)) {
  #(Model(room_id: ""), [])
}

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model, Msg) {
  case ev {
    socket.Join("room:" <> room_id, _payload, ref) ->
      socket.Next(Model(room_id: room_id), [
        socket.AcceptJoin(
          ref,
          Some(json.object([#("room_id", json.string(room_id))])),
        ),
      ])

    socket.Message(_topic, "ping", _payload, Some(ref)) ->
      socket.Next(model, [
        socket.ReplyOk(ref, json.object([#("status", json.string("ok"))])),
      ])

    socket.Message(topic, "typing", _payload, _ref) ->
      socket.Next(model, [
        socket.BroadcastFrom(topic, "typing", json.object([])),
      ])

    socket.Info(Tick(at)) ->
      socket.Next(model, [
        socket.Push(
          "room:" <> model.room_id,
          "tick",
          json.object([#("at", json.int(at))]),
        ),
      ])

    _ -> socket.Next(model, [])
  }
}
```

Three shifts to notice, common to both layers:

- **Side effects are values.** Phoenix callbacks call `push` and
  `broadcast_from!` imperatively; a beryl callback returns a list, and the
  runtime applies it strictly in order after the turn ends. List order is wire
  order, so an acknowledgment followed by a push guarantees the client sees
  them in that order.
- **Join acks are explicit and fail closed.** Phoenix infers the ack from
  `join/3`'s return value. In beryl you answer with `accept`/`reject` (layer)
  or `AcceptJoin`/`RejectJoin` (core); a join left unanswered is rejected
  automatically, and with the layer a topic no handler claims is refused with
  `{"reason": "unmatched topic"}`.
- **Server-side messages are typed.** Phoenix's `handle_info` receives any
  term. The channel layer's `on_info` receives *this channel's* own `info`
  type, delivered through the `channel.Sender(info)` in `JoinInfo.self`; raw
  dispatch's `Info(msg)` carries the socket's `msg` type. Nothing is coerced in
  either direction — the layer seals the typed value in a closure and stamps
  the envelope with the join it belongs to, so a send to a channel that has
  closed, or to a topic that has since been rejoined, is dropped rather than
  delivered to the wrong join.

## Assigns become a typed state value

`socket.assigns` is a map; a channel's state is a record you define:

```gleam
type State {
  State(room_id: String, username: String, joined_at: Int)
}
```

There is no `assign/3`: a callback returns the next state directly, for example
with `channel.continue_with(State(..state, joined_at: now), actions)`. Because
the state type is sealed inside the channel's closures, two channels in the
same handler table can have states with nothing in common — and the compiler
still checks every field access.

## Presence and the `:after_join` dance

The common Phoenix pattern sends itself a message so tracking happens after the
join is acknowledged:

```elixir
def handle_info(:after_join, socket) do
  {:ok, _} = Presence.track(socket, socket.assigns.user_id, %{status: "online"})
  push(socket, "presence_state", Presence.list(socket))
  {:noreply, socket}
end
```

You do not need the self-send. `channel.with_actions` attaches actions to the
accepted join; they are applied strictly after the acknowledgment, so the
socket is already subscribed:

```gleam
channel.accept(channel.joined(state, callbacks()))
|> channel.with_actions(
  channel.actions()
  |> channel.presence_track(
    "user:" <> state.user_id,
    json.object([#("status", json.string("online"))]),
  )
  |> channel.push_presence("presence_state", presence_wire.encode_state),
)
```

Snapshot actions encode when they are applied, so `presence_state` already
includes the `presence_track` ahead of it. The same holds in raw dispatch,
where the effects go in one list after `AcceptJoin`. Presence mutations are
asynchronous in the runtime: this socket resumes in order after the mutation,
while other sockets may continue in the meantime.

The mirror image — Phoenix's `terminate/2` — is `channel.on_terminate`, which
returns actions of its own, so a leave announcement and a post-leave roster
stay inside the channel:

```gleam
channel.on_terminate(fn(state: State, _reason) {
  channel.actions()
  |> channel.presence_untrack("user:" <> state.user_id)
  |> channel.broadcast_presence("presence_state", presence_wire.encode_state)
})
```

The topic is already unsubscribed at that point and its reply refs are already
purged, so `push` and `reply_ok`/`reply_error` actions are dropped while
broadcasts and `presence_untrack` still apply. See
[Termination](/guides/channels/#termination).

The wire payloads (`presence_state`, `presence_diff`) match Phoenix Presence's
shapes. See the [Presence guide](/guides/presence/) for setup and cross-node
replication.

## Broadcasting from outside a socket

Where you would call `MyAppWeb.Endpoint.broadcast("room:lobby", "notice", %{})`
from a controller or background job, call `beryl.broadcast` with the `Sockets`
handle returned by `beryl_channels.child_spec` or `beryl.child_spec`:

```gleam
beryl.broadcast(sockets, "room:lobby", "notice", json.object([]))
```

With PubSub configured, `beryl.broadcast` distributes across the cluster, the
same way `Endpoint.broadcast` rides `Phoenix.PubSub`.

This is also how a channel reaches **another** topic. Channel actions are
scoped to the channel's own topic on purpose, and the `Sockets` handle only
becomes available after `child_spec` returns — so an app that needs cross-topic
publishing keeps the handle in a small actor and calls it from its callbacks.
That actor is the layer's `Endpoint.broadcast/3`; see
[Limitations](/guides/channels/#limitations).

To message one specific channel (Phoenix: `send(channel_pid, msg)`), keep the
`channel.Sender(info)` from `JoinInfo.self` and call `channel.notify` — the
message arrives as a typed `on_info` call. With raw dispatch, keep the
`socket.Sender(msg)` from `ConnectInfo.self` and call `socket.notify`.

## Next steps

- [Channels](/guides/channels/) — the full channel-layer guide
- [App-Side Dispatch](/guides/dispatch/) — the full routing model, topic helpers, and effect ordering
- [Choose an API](/choosing-an-api/) — which layer fits your app
- [WebSocket Transport](/guides/websocket/) — mount beryl on Mist or Ewe, Phoenix-compatible framing
- [Presence](/guides/presence/) — tracking, snapshots, and cross-node sync
- [PubSub](/guides/pubsub/) — the `pg`-backed publish/subscribe layer
