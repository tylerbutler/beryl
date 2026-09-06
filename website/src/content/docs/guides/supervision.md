---
title: Supervision
description: Add beryl processes to an OTP supervisor and understand restart and shutdown behavior.
---

beryl has no unsupervised mode. `beryl.child_spec` returns a stable `Sockets`
handle and a child specification. Add the specification to your application's
OTP supervisor. The specification contains your `init` and `update` functions.
`channel.child_spec` returns the same handle and specification shape. It first
converts the handler table to a core `init` and `update` pair.

## Processes in the child specification

```text
beryl internal supervisor (one-for-one, 3 restarts / 5 seconds)
|- socket factory supervisor (Permanent)
|  `- socket actor (one per connection, Temporary)
|     `- topic worker supervisor (channel layer only, linked to the socket actor)
|        `- topic worker (one per accepted socket/topic join, Temporary)
|- router actor (Transient, significant)
`- connection limiter (optional)

transport connection process (outside the beryl subtree)
`- owns the WebSocket and performs frame writes
```

- The **router actor** maintains the socket actor table and topic subscriber
  index. If the router crashes, the supervisor restarts it. The child
  specification still contains the `init` and `update` functions.
- Each **socket actor** holds one model and sends events to your `update`
  function. The transport requests a `Temporary` child from the shared
  **socket factory supervisor**. The router monitors and registers it before
  `init` runs in the socket actor. A slow `init` does not hold the factory's
  child-start operation or the router's admission turn.
- With the channel layer, each socket actor starts a **topic worker
  supervisor** and one **topic worker** for each accepted join. Workers are
  `Temporary`. The supervisor does not restart a stopped worker. The client
  must rejoin. The workers stop with their socket actor.
- The router uses a stable registered name. The `Sockets` handle accepts new
  work after a restart. Existing connections close. Sends during the restart
  window do nothing.
- The factory is `Permanent`. If it crashes, its socket actors stop and their
  connections close. The router removes their routing and presence state but
  does not restart. The replacement factory accepts new connections.
- The router is the significant `Transient` child: a graceful `beryl.stop`
  shuts down the subtree and is not restarted.

After **3 restarts in 5 seconds** the internal supervisor gives up and the
failure propagates through your application's supervision tree.

`Temporary` supervision owns process shutdown; it does not reconstruct a
session. A stopped socket actor is not restarted. The client must reconnect
and rejoin. A stopped topic worker is not restarted either; the client must
rejoin that topic. Store durable application data outside these processes.

## Runtime restarts close connections

A runtime restart drops **per-socket state**: models, joined topics, and
pending joins. Transports monitor the runtime that accepted each connection,
so those WebSockets close and clients reconnect and rejoin normally.

Crashes inside `update` do **not** restart the runtime. beryl catches callback
crashes and limits their effect:

| Crash site | Effect |
|------------|--------|
| `init` | The connecting socket is not registered; others unaffected |
| `update` on `Join` | The join is rejected; the socket survives |
| `update` on `Message`/`Binary` | Only that topic is closed |
| `update` on `Info` | The socket is torn down |
| `update` on `Closed` | Logged; the close completes anyway |

Raw dispatch callbacks run in the socket actor. A callback crash in that actor
would close every topic on the socket. beryl catches a callback crash when it
can discard the result and close only the affected topic or socket. Other socket
actor faults close only that socket, and the router removes its entries. A
router fault reaches the supervisor and closes all connections. See
[What closes after a callback panic](/architecture/runtime/#what-closes-after-a-callback-crash).

See the [Error Handling guide](/guides/error-handling/) for details.

Channel callbacks run in the topic's worker. A `join`, `on_message`, or
`on_info` panic affects only that join or topic. An `on_terminate` panic
discards that callback's actions but does not stop cleanup for sibling
channels. See
[When callbacks panic](/guides/channels/#when-callbacks-panic).

## Slow callbacks and transport writes

Socket actors apply protocol effects in order. Their send functions enqueue
frames for the transport connection process; they do not write to the network.
A successful enqueue is not confirmation that the client received the frame.

A slow raw callback delays its whole socket. Channel message and info
callbacks run independently in topic workers, but joins and ordered closes
can make the socket actor wait for a worker. Presence mutations pause that
socket's ordered effect list. A slow shared presence actor can delay mutations
from many sockets. Router ingress and fan-out are also shared work.

Process isolation does not bound queues or guarantee latency for healthy
clients. See [Queue limits and overload](/architecture/runtime/#queue-limits-and-overload)
for the supported controls and the boundaries that remain unbounded.

## Supervise presence and groups

`presence.child_spec` and `group.child_spec` return stable handles and child
specifications, as the socket runtime does. Add all three specifications to
your application supervisor:

```gleam
import beryl
import beryl/group
import beryl/presence
import beryl/wire
import gleam/otp/static_supervisor

pub fn main() -> Nil {
  let #(presence_actor, presence_specification) =
    presence.child_spec(presence.default_config("node1"))
  let #(groups, groups_specification) = group.child_spec()

  let assert Ok(#(channels, beryl_specification)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: init,
      update: update,
    )
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(presence_specification)
    |> static_supervisor.add(groups_specification)
    |> static_supervisor.add(beryl_specification)
    |> static_supervisor.start()

  // ... start the transport, run forever
  Nil
}
```

Presence is a separate actor that the application owns. From socket code, use
`socket.PresenceTrack` and `PresenceUntrack` effects or the channel actions.
The runtime pauses only the affected socket until the mutation completes. Do
not call the synchronous public presence API from `init`, `update`, or a
channel callback.

Both handles are name-backed and reach the replacement actor after a supervised
restart. Presence entries and tracking refs, and group definitions and
memberships, are in-memory state and reset when their actor restarts.

:::note[PubSub is not supervised]
`beryl/pubsub` uses Erlang's `pg` module, which the BEAM runtime manages.
Configure it with `beryl.with_pubsub`.
:::

## Startup errors

`child_spec` validates its configuration before allocating the subtree:

```gleam
case beryl.child_spec(config, init: init, update: update) {
  Ok(#(sockets, runtime_specification)) ->
    add_to_supervisor(sockets, runtime_specification)
  Error(beryl.HeartbeatTimeoutTooLow(2)) ->
    // heartbeat_timeout_ms below 2 would silently disable eviction
    panic as "fix the heartbeat config"
  Error(beryl.InvalidTopicPattern(pattern, _reason)) ->
    panic as "invalid topic pattern: " <> pattern
}
```

## Stop the runtime

`beryl.stop(channels)` sends a `Closed` event to each joined topic. It closes
transport connections and stops the runtime without a restart. A second call
returns `Error(NotRunning)`. Other operations after `stop` do nothing.

## Production checklist

- Add the returned specification to your long-lived application supervisor.
- Add application-owned presence and group child specifications alongside the
  beryl child.
- Configure PubSub when running more than one BEAM node.
- Configure rate limits to protect against faulty or hostile clients. See
  [Production Hardening](/guides/production-hardening/).
