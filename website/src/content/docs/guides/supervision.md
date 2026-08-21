---
title: Supervision
---

Beryl has no unsupervised mode. `beryl.child_spec` returns a stable `Sockets`
handle and a child specification. Add the specification to your application's
OTP supervisor. The specification contains your `init` and `update` functions.
`channel.child_spec` returns the same handle and specification shape. It first
converts the handler table to a core `init` and `update` pair.

## What child_spec supervises

```text
beryl internal supervisor (one-for-one, 3 restarts / 5 seconds)
`- runtime actor (Transient)
```

- The **runtime actor** holds each socket model and sends events to your
  `update` function. If the actor crashes, the supervisor restarts it. The
  child specification still contains the `init` and `update` closures. You do
  not need to register them again.
- The runtime uses a stable registered name. The `Sockets` handle and transport
  connections keep working after a restart. Sends during the restart window do
  nothing.
- The child is `Transient`: a graceful `beryl.stop` is final and is not
  resurrected.

After **3 restarts in 5 seconds** the internal supervisor gives up and the
failure propagates through your application's supervision tree.

## What a restart means for your app

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

All app callbacks run in one runtime actor. A supervisor restart for one
callback would discard all socket models and close all connections on the
`Sockets` handle. Beryl catches a callback crash only when it can discard the
result and close the smallest safe scope. Other runtime faults reach the
supervisor. See
[Runtime crash containment](/architecture/runtime/#crash-containment).

See the [Error Handling guide](/guides/error-handling/) for details.

For channel callbacks, those rows map to `join`, `on_message`/`on_binary`,
`on_info`, and `on_terminate`. A terminate panic loses that callback's actions
but does not stop sibling-channel teardown; see
[Crash behavior](/guides/channels/#crash-behavior).

## Presence and groups

`presence.child_spec` and `group.child_spec` return stable handles and child
specifications, just like the socket runtime. Add all three specifications to
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
`beryl/pubsub` is backed by Erlang's `pg` module, whose lifecycle is
managed by the BEAM runtime. Configure it with `beryl.with_pubsub`.
:::

## Startup errors

`child_spec` validates its configuration before allocating the subtree:

```gleam
case beryl.child_spec(config, init: init, update: update) {
  Ok(#(sockets, spec)) -> add_to_supervisor(sockets, spec)
  Error(beryl.HeartbeatTimeoutTooLow(2)) ->
    // heartbeat_timeout_ms below 2 would silently disable eviction
    panic as "fix the heartbeat config"
  Error(beryl.InvalidTopicPattern(pattern, reason)) ->
    panic as pattern <> ": " <> reason
}
```

## Stopping

`beryl.stop(channels)` sends a `Closed` event to each joined topic. It closes
transport connections and stops the runtime without a restart. A second call
returns `Error(NotRunning)`. Other operations after `stop` do nothing.

## Production checklist

- Add the returned specification to your long-lived application supervisor.
- Add application-owned presence and group child specifications alongside the
  Beryl child.
- Configure PubSub when running more than one BEAM node.
- Configure rate limits to protect against runaway clients — see
  [Production Hardening](/guides/production-hardening/).
