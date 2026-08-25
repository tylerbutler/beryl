---
title: Coming from Phoenix
description: Compare Phoenix Channels modules, callbacks, assigns, and Presence with both beryl APIs.
---

beryl speaks the same wire protocol as Phoenix Channels (`phx_join`, refs,
heartbeats, `presence_state`/`presence_diff`), so Phoenix client libraries
work without changes. The server programming model is different. This page
compares the two systems.

beryl gives you two layers, and Phoenix maps onto both:

- **`beryl/channel`, the channel layer:** This is the closest match and the
  recommended default for a Phoenix style app. Register one handler for each
  topic pattern. Each channel has callbacks and private state.
- **`beryl`, raw app-side dispatch:** This is the core API. Define one `init`
  and `update` pair for the socket system. Beryl runs them separately for each
  connected socket. Your `update` function owns topic dispatch.

[Choose an API](/choosing-an-api/) compares both APIs. Both support
colon-delimited topics, wildcard patterns, CRDT presence, `pg` PubSub,
heartbeats, and the Phoenix JSON array format.

## The core difference: processes and state

In Phoenix, the framework owns the router and process tree. You define a
routing table in the socket module, such as
`channel "room:*", RoomChannel`. Phoenix starts **one channel process for each
joined topic**. It calls `join`, `handle_in`, `handle_info`, and `terminate`.
Each callback receives channel state in `socket.assigns`, which is a map of
atoms to untyped terms.

beryl starts **one socket actor for each connected socket**, not one process
for each joined topic. A separate router actor maintains the socket and topic
indexes. With the channel layer, all channels on one socket run in sequence in
that socket's actor. Each channel has a private state value of your type. Raw
dispatch has no handler table: one `update` receives every event for the socket
as `socket.Input(msg)`, and one `model` stores its state. Different socket
actors run concurrently.

This gives beryl a coarser isolation boundary than Phoenix. Different sockets
have separate actors, but channels on one socket share an actor mailbox,
execution context, and lifecycle. A slow callback delays every topic on that
socket. A fault in the socket actor closes all its topics.

Beryl rescues expected callback crashes with narrower behavior: a join panic
rejects that join, a message panic closes that topic, an `on_info` panic ends
the socket, and a terminate panic loses that callback's actions while teardown
continues. These rescue boundaries limit known callback failures, but they do
not provide Phoenix's process isolation between joined topics. See
[crash behavior](/guides/channels/#crash-behavior). Run long or blocking work
in another process and return results with `channel.notify` or
`socket.notify`.

[Issue #337](https://github.com/tylerbutler/beryl/issues/337) tracks a
Phoenix-style process-per-channel prototype.

## Concept map

| Phoenix | beryl channel layer (`beryl/channel`) | beryl raw dispatch (`beryl`) |
| --- | --- | --- |
| `socket "/socket", UserSocket` in the Endpoint | `beryl_mist` / `beryl_ewe` mounted on your HTTP server | same |
| `UserSocket.connect(params, socket)` | transport `on_connect`; request data reaches `join` as `context.seed` | `init(info)` — request data in `info.seed` |
| `channel "room:*", RoomChannel` routing table | the handler list passed to `channel.child_spec` | topic pattern match in `update`, with `beryl/topic` helpers |
| One channel process per joined topic | one socket actor per connection, with one private state value per joined topic | one socket actor and one `model` per connection, covering all its topics |
| `socket.assigns` + `assign/3` | the channel's own `state` type, returned from each callback | your `model`, returned from each `update` |
| `join/3` callback | the handler's `join` callback | `socket.Join(topic, payload, ref)` |
| `{:ok, socket}` / `{:ok, reply, socket}` | `channel.accept(state)` / `accept(..) |> channel.with_reply(reply)` | `socket.AcceptJoin(ref, None)` / `socket.AcceptJoin(ref, Some(reply))` |
| `{:error, %{reason: ...}}` | `channel.reject(reason)` | `socket.RejectJoin(ref, reason)` |
| `handle_in/3` | `channel.on_message` | `socket.Message(topic, event, payload, ref)` |
| `{:reply, {:ok, payload}, socket}` | `channel.reply_ok(message.reply, payload)` / `channel.reply_error(message.reply, payload)` action | `socket.ReplyOk(ref, payload)` / `socket.ReplyError(ref, payload)` |
| `{:noreply, socket}` | `channel.stay(state)` | `socket.Next(model, [])` |
| `socket_ref/1` + `Phoenix.Channel.reply/2` (reply later) | keep `Option(ReplyRef)` in the channel's state and call `reply_ok` from a later active callback | store the `ReplyRef` in your model, `socket.ReplyOk` from a later `update` turn |
| `push(socket, event, payload)` | `channel.push(event, payload)` action | `socket.Push(topic, event, payload)` effect |
| `broadcast!/3` | `channel.broadcast(event, payload)` action | `socket.Broadcast(topic, event, payload)` effect |
| `broadcast_from!/3` | `channel.broadcast_from(event, payload)` action | `socket.BroadcastFrom(topic, event, payload)` effect |
| `handle_info(msg, socket)` + `send(pid, msg)` | `channel.on_info` + `channel.notify(sender, msg)` — typed per channel | `socket.Info(msg)` + `socket.notify(sender, msg)` — typed per socket |
| `:after_join` self-send | `channel.with_actions` on the accepted join (ordered immediately after the ack) | order the effects after `AcceptJoin` in the same list |
| `terminate/2` | `channel.on_terminate`, which returns actions | `socket.Closed(topic, reason)` event, delivered on every exit path |
| `{:stop, reason, socket}` (ends one channel) | `channel.close(actions)` | `socket.KickTopic(topic)` |
| ending the whole socket | use raw dispatch | `socket.Stop(reason)` |
| `MyAppWeb.Endpoint.broadcast/3` from anywhere | `beryl.broadcast(sockets, topic, event, payload)` | same |
| `Phoenix.PubSub` | `beryl/pubsub`, also built on `pg` | same |
| `Phoenix.Presence.track/3` / `untrack/3` | `channel.presence_track(key, meta)` / `channel.presence_untrack(key)` actions | `socket.PresenceTrack(topic, key, meta)` / `socket.PresenceUntrack(topic, key)` effects |
| `Phoenix.Presence.update/4` | repeat `channel.presence_track(key, meta)`; for standalone refs, `presence.update(handle, ref, meta)` | repeat `socket.PresenceTrack(topic, key, meta)`; for standalone refs, `presence.update(handle, ref, meta)` |
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
import beryl/channel
import gleam/json

type State {
  State(room_id: String)
}

pub type Note {
  Tick(Int)
}

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(context: channel.JoinContext(Note)) {
    channel.accept(State(room_id: context.topic))
    |> channel.on_message(fn(state: State, message: channel.Message) {
      case message.event {
        "ping" ->
          channel.next(state, [
            channel.reply_ok(
              message.reply,
              json.object([#("status", json.string("ok"))]),
            ),
          ])

        "typing" ->
          channel.next(state, [
            channel.broadcast_from("typing", json.object([])),
          ])

        _ -> channel.stay(state)
      }
    })
    |> channel.on_info(fn(state: State, note: Note) {
      let Tick(at) = note
      channel.next(state, [
        channel.push("tick", json.object([#("at", json.int(at))])),
      ])
    })
    |> channel.with_reply(
      json.object([#("room_id", json.string(context.topic))]),
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

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model) {
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

Both beryl APIs differ from Phoenix in these ways:

- **Side effects are values.** Phoenix callbacks call `push` and
  `broadcast_from!`. A beryl callback returns a list. The runtime applies the
  list in order after the turn. List order is wire order, so an acknowledgment
  before a push reaches the client first.
- **Join acknowledgments are explicit and fail closed.** Phoenix infers the
  acknowledgment from the `join/3` return value. In beryl, return
  `accept` or `reject` from the channel layer. In raw dispatch, return
  `AcceptJoin` or `RejectJoin`. The runtime rejects an unanswered join. The
  channel layer rejects an unmatched topic with
  `{"reason": "unmatched topic"}`.
- **Server-side messages are typed.** Phoenix's `handle_info` receives any
  term. The channel layer's `on_info` receives *this channel's* own `info`
  type, delivered through the `channel.Sender(info)` in `JoinContext.self`; raw
  dispatch's `Info(msg)` wraps the socket's `msg` type. Nothing is coerced in
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
with `channel.next(State(..state, joined_at: now), actions)`. Because
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
accepted join. The runtime applies them after the acknowledgment, when the
socket has joined the topic:

```gleam
channel.accept(state)
|> channel.with_actions([
  channel.presence_track(
    "user:" <> state.username,
    json.object([#("status", json.string("online"))]),
  ),
  channel.push_presence("presence_state", presence_wire.encode_state),
])
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
|> channel.on_terminate(fn(state: State, _reason) {
  [
    channel.presence_untrack("user:" <> state.username),
    channel.broadcast_presence("presence_state", presence_wire.encode_state),
  ]
})
```

The closing phase allows broadcasts, presence untracking, and presence
broadcasts; active-only pushes, replies, and presence tracking do not
type-check there. See [Termination](/guides/channels/#termination).

The wire payloads (`presence_state`, `presence_diff`) match Phoenix Presence's
shapes. See the [Presence guide](/guides/presence/) for setup and cross-node
replication.

## Broadcasting from outside a socket

From a controller or background job, Phoenix uses
`MyAppWeb.Endpoint.broadcast("room:lobby", "notice", %{})`. In beryl, call
`beryl.broadcast` with the `Sockets` handle from `channel.child_spec` or
`beryl.child_spec`:

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
`channel.Sender(info)` from `JoinContext.self` and call `channel.notify` — the
message arrives as a typed `on_info` call. With raw dispatch, keep the
`socket.Sender(msg)` from `ConnectInfo.self` and call `socket.notify`.

## Next steps

- [Channels](/guides/channels/) — the full channel-layer guide
- [App-Side Dispatch](/guides/dispatch/) — the full routing model, topic helpers, and effect ordering
- [Choose an API](/choosing-an-api/) — which layer fits your app
- [WebSocket Transport](/guides/websocket/) — mount beryl on Mist or Ewe, Phoenix-compatible framing
- [Presence](/guides/presence/) — tracking, snapshots, and cross-node sync
- [PubSub](/guides/pubsub/) — the `pg`-backed publish/subscribe layer
