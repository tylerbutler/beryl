---
title: Where the analogy ends
description: Follow a frame through beryl and learn where frontend model-update ideas stop matching runtime behavior.
---

The model-update words from the last chapters help you organize your code.
But they can give you the wrong idea about how beryl runs that code. beryl
gives each socket its own actor. An actor is a process with a mailbox that
handles one message at a time. But beryl does not draw a view from your model.
It does not bring your socket state back after a crash. One router actor keeps
the list of sockets and sends broadcasts to them. Each socket actor calls your
update function and runs the effects it returns, in order.

The production decisions start where the frontend analogy ends.

## Follow one frame

A frame is one WebSocket message. For a text frame, the path is:

```text
transport connection
  -> configured wire codec
  -> beryl router actor
  -> socket actor
  -> app update or channel callback
  -> returned effects or actions
  -> encoded WebSocket frame or broadcast to subscribers
```

The transport owns the WebSocket connection. It does the first checks: is the
frame too large, and is the client sending too many frames? Then it decodes the
frame with your wire codec and sends the result to the router. Bad input and
decode work stay in the connection process. They do not reach your code.

The router sends the decoded value to the socket actor. That actor checks the
protocol state and builds a `socket.Input`. With raw dispatch, your update
function receives that input. With `beryl/channel`, the channel layer finds the
live channel for that topic, calls its callback, and turns the actions into core
effects.

The socket actor then runs the effects in list order. A reply or push becomes an
encoded frame. A broadcast goes to the router. The router sends it to the local
sockets, and to PubSub if you configured it.

The client payload is the only `Dynamic` value on this path. Your model and
message types stay inside typed closures. The channel layer does the same for
each handler's state and info type.

## Each socket model has one actor

Raw `init` runs once for each socket. It returns one `Model`. With channels,
each accepted topic gets its own state value. Those values are separate from
each other, but one socket actor stores all of them for its socket.

The socket actor handles its mailbox one message at a time. So it always has a
consistent view of its model, its topics, and its heartbeat time. It needs no
locks. The router has its own mailbox for the socket list and topic subscriber
sets. If your update function blocks, only that socket waits. But that socket's
later messages, effects, and heartbeat checks also wait.

The live-poll example follows that rule:

- `store.Store` keeps the shared poll state in its own actor;
- `timer.Timer` waits and runs delayed callbacks in its own actor;
- beryl callbacks make short calls, pick the next state, and return effects.

If some work takes a long time, do not run it in a callback. Run it under your
own supervision. Then send a typed result back through `socket.Sender` or
`channel.Sender`.

## A callback crash closes the smallest affected part

In Erlang, "let it crash" means: let a process die and let its supervisor
restart it. If beryl did that here, one bad callback would close every topic on
its socket. Instead, beryl catches the crash. What happens next depends on
which input failed:

| Callback or raw input | Runtime behavior |
|---|---|
| raw `init` | Leave the socket unregistered |
| `Join`, or a channel `join` | Reject that join |
| topic-scoped `Message`, or `on_message` | Close that topic |
| `Info`, or channel `on_info` | Tear down that socket |
| `Closed`, or channel `on_terminate` | Log the crash and continue teardown |

Other socket actors keep running. If a socket actor crashes somewhere else,
only that actor stops. The router sees this, closes the connection, and removes
the socket from its list. beryl cuts long crash descriptions before it logs
them.

The `on_terminate` case has one special behavior in the channel layer. If the
callback panics, beryl drops the router update and the actions it returned.
The channel's sender can still reach the old channel until the client joins the
topic again or the socket ends. Client traffic cannot reach it, because the
topic is closed. Keep `on_terminate` small. Do not do half-finished work there.

This policy contains crashes in your callbacks. It does not pretend that every
crash has the same size.

## A restart restores the service, not socket state

`beryl.child_spec` and `channel.child_spec` return a child specification. You
put it in your application's supervisor. If the router dies, the supervisor
restarts it under the same `beryl.Sockets` handle. When the router dies, all
socket actors stop too. Connected clients see the connection close. They
reconnect and join again with new models and new channel state. If one socket
actor crashes, only its connection closes. The router does not restart.

Keep domain state that must survive in storage that your app owns. The example
does this with `store.Store`. The next chapter covers the supervision tree,
restart windows, restart intensity, and graceful shutdown.

## Heartbeats test that a connection is alive

Phoenix clients send a heartbeat frame on the `phoenix` topic at a regular
interval. beryl handles heartbeats inside each socket actor. Your update
function does not see them. Each actor records the time of the last heartbeat
and runs its own timer to check it. There is no global check across all
sockets.

If a socket misses its heartbeat, beryl closes the transport. It then delivers
`Closed(topic, HeartbeatTimeout)` for every joined topic. Raw dispatch can
remove the topic from its model. The channel layer calls `on_terminate` for
each channel.

The final checkpoint sets:

```gleam
beryl.config(wire.phoenix_codec())
|> beryl.with_heartbeat(timeout_ms: 45_000)
|> beryl.with_max_connections(500)
|> beryl.with_max_connections_per_ip(20)
|> beryl.with_max_inbound_frame_bytes(16_384)
|> beryl.with_frame_rate(per_second: 20, burst: 40)
|> beryl.with_message_rate(per_second: 10, burst: 20)
|> beryl.with_join_rate(per_second: 4, burst: 8)
|> beryl.with_topic_rate(pattern: "poll:*", per_second: 5, burst: 10)
```

This exact excerpt comes from
[`step_05.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/step_05.gleam).
These values make the example look like a production app. They are not correct
for every app. Choose your limits from the traffic you expect and the capacity
you have.

## PubSub and presence follow different rules

PubSub sends broadcasts between BEAM nodes. It uses Erlang `pg`, the built-in
process group library. A remote payload and its subscribers are a distributed
messaging problem, not part of a local model-update-view loop. When the router
receives a broadcast, it sends it to the local socket actors.

Presence tracks which clients are on a topic. It is an actor that your app
owns. It stores a CRDT, which is a data structure that many nodes can change
and still agree on. A presence effect can pause the rest of the effect list
for one socket while the presence actor applies the change. Other sockets,
heartbeats, broadcasts, and shutdown keep going. When the change is done, the
socket runs the rest of its list in the original order.

PubSub and presence are not hidden fields in your socket `Model`. Each one starts, stops, and communicates across nodes in its own way:

- configure PubSub when broadcasts must cross nodes;
- start and supervise presence when clients need a shared member list;
- keep capacity or authorization state in a process your app owns when a check
  and a change must happen together.

The Elm analogy explains state changes. It does not explain cluster membership,
CRDT agreement, or supervision.

## Raw dispatch or channels

Both APIs use the same transport, runtime, codec, presence, PubSub, and abuse
controls. Choose based on where you want the routing to live.

Use raw dispatch when:

- the endpoint serves one topic family;
- one socket-wide model is natural;
- callbacks need effects on several topics in one ordered list;
- you want to write the routing yourself.

Use `beryl/channel` when:

- the endpoint serves several topic namespaces;
- the design follows Phoenix Channels;
- each channel should own its own state and info type;
- you want to compose handlers as values.

Raw dispatch is the core programming model and the clearest one to learn from.
For apps with many channels, or apps shaped like Phoenix, use `beryl/channel`.
Channel actions apply only to the current topic, and only some actions are
allowed during close. Raw effects can name any topic, so work across topics is
normal app code.

## Rules to remember

The earlier chapters started with a familiar update loop. In production, keep
these differences in view:

- beryl has no `view`.
- Raw `init` runs once per socket.
- One actor stores each socket model. A separate router stores the socket list
  and the subscribers.
- Client payload stays `Dynamic` until your code decodes it.
- `JoinRef` and `ReplyRef` are protocol tokens. Do not try to rebuild them.
- The order of your effect list is the order on the wire.
- Raw effects can work across topics. Channel actions apply to one topic, and
  the close phase allows fewer of them.
- beryl catches callback crashes. The size of the cleanup depends on the input.
- A supervisor restart brings dispatch back. It does not bring live socket
  state back.

These rules tell you where to put state and work. Keep facts about one
connection in raw models or channel state. Keep shared app state in
processes your app owns. Decode client data after beryl reads the frame. Return short, ordered
effect lists. Let supervision restore services. Let clients restore their
subscriptions when they reconnect.

## Sources and further reading

- [beryl runtime architecture](/architecture/runtime/)
- [How beryl handles a message](/architecture/message-lifecycle/)
- [Choose a beryl API](/choosing-an-api/)
- [`beryl` source](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl.gleam)
- [`beryl/socket` source](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl/socket.gleam)
- [`beryl/channel` source](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl/channel.gleam)

## Runnable checkpoint: step 05

```sh
cd examples/live_poll && gleam run -m live_poll/step_05
```

Open `http://localhost:8105`, join `demo`, vote from two tabs, and close the
poll now or wait 60 seconds. The behavior matches step 04, but the runtime now
uses the heartbeat and abuse-control settings shown above. In another shell,
run `curl http://localhost:8105/healthz`. The expected response is `ok`.

Next: [Supervising beryl](/tutorial/supervising-beryl/).
