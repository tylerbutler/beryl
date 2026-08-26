---
title: Coming from Phoenix
description: Map Phoenix Channels processes, callbacks, assigns, and Presence to both Beryl APIs.
---

When configured with `wire.phoenix_codec()`, beryl speaks the same wire
protocol as Phoenix Channels (`phx_join`, refs, heartbeats,
`presence_state`/`presence_diff`), so Phoenix client libraries work without
changes. The server programming model is different. This page compares the
two systems.

beryl gives you two layers, and Phoenix maps onto both:

- **`beryl/channel`, the channel layer:** This is the closest match and the
  recommended default for a Phoenix style app. Register one handler for each
  topic pattern. Each channel has callbacks and private state.
- **`beryl`, raw dispatch:** This is the core API. Define one `init`
  and `update` pair for the socket system. Beryl runs them separately for each
  connected socket. Your `update` function owns topic dispatch.

[Choose an API](/choosing-an-api/) compares both APIs. Both support
colon-delimited topics, wildcard patterns, CRDT presence, `pg` PubSub,
and heartbeats. Both use the Phoenix JSON array format when configured with
`wire.phoenix_codec()`.

## Compare processes and state

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

Beryl provides less fault isolation between joined topics than Phoenix.
Different sockets have separate actors, but channels on one socket share an
actor mailbox, execution time, and lifecycle. A slow callback delays every
topic on that socket. A fault in the socket actor closes all its topics.

Beryl catches expected callback panics with narrower behavior: a join panic
rejects that join, a message panic closes that topic, an `on_info` panic ends
the socket, and a terminate panic loses that callback's actions while teardown
continues. These rules limit known callback failures, but they do
not provide Phoenix's process isolation between joined topics. See
[callback panics](/guides/channels/#when-callbacks-panic). Run long or blocking work
in another process and return results with `channel.notify` or
`socket.notify`.

[Issue #337](https://github.com/tylerbutler/beryl/issues/337) tracks a
Phoenix-style process-per-channel prototype.

## Phoenix-to-Beryl comparison

| Phoenix | beryl channel layer (`beryl/channel`) | beryl raw dispatch (`beryl`) |
| --- | --- | --- |
| `socket "/socket", UserSocket` in the Endpoint | `beryl_mist` / `beryl_ewe` mounted on your HTTP server | same |
| `UserSocket.connect(params, socket)` | transport `on_connect`; request data reaches `join` as `context.seed` | `init(info)`; request data is in `info.seed` |
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
| `handle_info(msg, socket)` + `send(pid, msg)` | `channel.on_info` + `channel.notify(sender, msg)`; typed per channel | `socket.Info(msg)` + `socket.notify(sender, msg)`; typed per socket |
| `:after_join` self-send | `channel.with_actions` on the accepted join (ordered immediately after the ack) | order the effects after `AcceptJoin` in the same list |
| `terminate/2` | `channel.on_terminate`, which returns actions | `socket.Closed(topic, reason)` event, delivered on every exit path |
| `{:stop, reason, socket}` (ends one channel) | `channel.close(actions)` | `socket.KickTopic(topic)` |
| ending the whole socket | use raw dispatch | `socket.Stop(reason)` |
| `MyAppWeb.Endpoint.broadcast/3` from anywhere | `beryl.broadcast(sockets, topic, event, payload)` | same |
| `Phoenix.PubSub` | `beryl/pubsub`, also built on `pg` | same |
| `Phoenix.Presence.track/3` / `untrack/3` | `channel.presence_track(key, meta)` / `channel.presence_untrack(key)` actions | `socket.PresenceTrack(topic, key, meta)` / `socket.PresenceUntrack(topic, key)` effects |
| `Phoenix.Presence.update/4` | repeat `channel.presence_track(key, meta)`; for standalone refs, `presence.update(handle, ref, meta)` | repeat `socket.PresenceTrack(topic, key, meta)`; for standalone refs, `presence.update(handle, ref, meta)` |
| `push(socket, "presence_state", Presence.list(socket))` | `channel.push_presence("presence_state", presence_wire.encode_state)` | `socket.PushPresence(topic, "presence_state", presence_wire.encode_state)` |
| `intercept` / `handle_out` | no equivalent; create payloads before `broadcast`, or use `push` for one socket | no equivalent; use the same approach |

## Compare room channel examples

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

The channel layer follows the same structure: one module per channel,
callbacks in that module, and per-topic state. It turns the imperative
`push` and `broadcast_from!` calls into ordered action values:

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

Raw dispatch puts the same behavior in branches of one `case` and names the
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
  type, delivered through the `channel.Sender(info)` in `JoinContext.self`.
  Raw dispatch's `Info(msg)` wraps the socket's `msg` type. Beryl keeps the
  value typed and records which join owns it. If that join closes or the topic
  joins again, Beryl drops the message instead of delivering it to the wrong
  join.

## Assigns become a typed state value

`socket.assigns` is a map; a channel's state is a record you define:

```gleam
type State {
  State(room_id: String, username: String, joined_at: Int)
}
```

There is no `assign/3`: a callback returns the next state directly, for example
with `channel.next(State(..state, joined_at: now), actions)`. Because
the channel keeps its state type private, two channels in the same handler
table can use unrelated state types. The compiler still checks every field
access.

## Replace the `:after_join` self-send

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

Phoenix's `terminate/2` maps to `channel.on_terminate`, which returns actions.
This keeps a leave announcement and updated roster inside the channel:

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
type-check there. See
[Handle channel termination](/guides/channels/#handle-channel-termination).

The wire payloads (`presence_state`, `presence_diff`) match Phoenix Presence's
shapes. See the [Presence guide](/guides/presence/) for setup and cross-node
replication.

## Broadcast from outside a socket

From a controller or background job, Phoenix uses
`MyAppWeb.Endpoint.broadcast("room:lobby", "notice", %{})`. In beryl, call
`beryl.broadcast` with the `Sockets` handle from `channel.child_spec` or
`beryl.child_spec`:

```gleam
beryl.broadcast(sockets, "room:lobby", "notice", json.object([]))
```

With PubSub configured, `beryl.broadcast` distributes across the cluster, the
same way `Endpoint.broadcast` rides `Phoenix.PubSub`.

This is also how a channel sends to **another** topic. Channel actions apply
only to their own topic, and the `Sockets` handle becomes available after
`child_spec` returns. An application that sends across topics can keep the
handle in a small actor and call it from channel callbacks.
That actor is the layer's `Endpoint.broadcast/3`; see
[When to use raw dispatch or another process](/guides/channels/#when-to-use-raw-dispatch-or-another-process).

To message one specific channel (Phoenix: `send(channel_pid, msg)`), keep the
`channel.Sender(info)` from `JoinContext.self` and call `channel.notify`. The
message arrives as a typed `on_info` call. With raw dispatch, keep the
`socket.Sender(msg)` from `ConnectInfo.self` and call `socket.notify`.

## Next steps

- [Channels](/guides/channels/): build handlers with private state and callbacks
- [Raw Dispatch](/guides/dispatch/): route socket events and order effects
- [Choose an API](/choosing-an-api/): compare channels and raw dispatch
- [WebSocket Transport](/guides/websocket/): connect Beryl to Mist
- [Presence](/guides/presence/): track users and synchronize nodes
- [PubSub](/guides/pubsub/): publish to subscribers through Erlang `pg`
