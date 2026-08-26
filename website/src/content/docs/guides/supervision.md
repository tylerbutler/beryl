---
title: Supervision
description: Add Beryl processes to an OTP supervisor and understand restart and shutdown behavior.
---

Beryl has no unsupervised mode. `beryl.child_spec` returns a stable `Sockets`
handle and a child specification. Add the specification to your application's
OTP supervisor. The specification contains your `init` and `update` functions.
`channel.child_spec` returns the same handle and specification shape. It first
converts the handler table to a core `init` and `update` pair.

## Processes in the child specification

```text
beryl internal supervisor (one-for-one, 3 restarts / 5 seconds)
|- router actor (Transient)
`- connection limiter (optional)

transport connection
`- socket actor (one per connection, monitored by the router)
```

- The **router actor** maintains the socket actor table and topic subscriber
  index. If the router crashes, the supervisor restarts it. The child
  specification still contains the `init` and `update` functions.
- Each **socket actor** holds one model and sends events to your `update`
  function. Socket actors are not supervisor children. The transport starts
  them, and the router monitors them.
- The router uses a stable registered name. The `Sockets` handle accepts new
  work after a restart. Existing connections close. Sends during the restart
  window do nothing.
- The child is `Transient`: a graceful `beryl.stop` is final and is not
  resurrected.

After **3 restarts in 5 seconds** the internal supervisor gives up and the
failure propagates through your application's supervision tree.

## Runtime restarts close connections

A runtime restart drops **per-socket state**: models, joined topics, and
pending joins. Transports monitor the runtime that accepted each connection,
so those WebSockets close and clients reconnect and rejoin normally.

Crashes inside `update` do **not** restart the runtime. Beryl catches callback
crashes and limits their effect:

| Crash site | Effect |
|------------|--------|
| `init` | The connecting socket is not registered; others unaffected |
| `update` on `Join` | The join is rejected; the socket survives |
| `update` on `Message`/`Binary` | Only that topic is closed |
| `update` on `Info` | The socket is torn down |
| `update` on `Closed` | Logged; the close completes anyway |

Each socket's callbacks run in its socket actor. A callback crash in that actor
would close every topic on the socket. Beryl catches a callback crash when it
can discard the result and close only the affected topic or socket. Other socket
actor faults close only that socket, and the router removes its entries. A
router fault reaches the supervisor and closes all connections. See
[What closes after a callback panic](/architecture/runtime/#what-closes-after-a-callback-crash).

See the [Error Handling guide](/guides/error-handling/) for details.

For channel callbacks, those rows map to `join`, `on_message`, `on_info`, and
`on_terminate`. A terminate panic loses that callback's actions but does not
stop sibling-channel teardown; see
[When callbacks panic](/guides/channels/#when-callbacks-panic).

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

pub fn main() {
  let #(presence_actor, presence_spec) =
    presence.child_spec(presence.default_config("node1"))
  let #(groups, groups_spec) = group.child_spec()

  let assert Ok(#(channels, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: init,
      update: update,
    )
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(presence_spec)
    |> static_supervisor.add(groups_spec)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  // ... start the transport, run forever
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
  Ok(#(sockets, spec)) -> add_to_supervisor(sockets, spec)
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
  Beryl child.
- Configure PubSub when running more than one BEAM node.
- Configure rate limits to protect against faulty or hostile clients. See
  [Production Hardening](/guides/production-hardening/).
