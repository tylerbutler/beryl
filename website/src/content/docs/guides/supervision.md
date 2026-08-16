---
title: Supervision
---

Beryl has no unsupervised mode. `beryl.child_spec` returns a stable `Sockets`
handle and a child specification that you add to your application's OTP
supervisor. Your `init`/`update` functions are captured in that specification.
`beryl_channels.child_spec` returns the same handle/spec shape after compiling
its handler table into the core `init`/`update` pair.

## What child_spec supervises

```text
beryl internal supervisor (one-for-one, 3 restarts / 5 seconds)
`- runtime actor (Transient)
```

- The **runtime actor** holds every socket's model and dispatches events to
  your `update` function. If it crashes, the supervisor restarts it with
  dispatch intact — the `init`/`update` closures live in the child
  specification, so no re-registration step exists or is needed.
- The runtime is registered under a stable name, so the `Sockets` handle
  (and every transport connection holding it) keeps working across
  restarts. Sends that race a restart window degrade to quiet no-ops
  instead of crashes.
- The child is `Transient`: a graceful `beryl.stop` is final and is not
  resurrected.

After **3 restarts in 5 seconds** the internal supervisor gives up and the
failure propagates through your application's supervision tree.

## What a restart means for your app

A runtime restart drops **per-socket state**: models, joined topics, and
pending joins. Transports monitor the runtime that accepted each connection,
so those WebSockets close and clients reconnect and rejoin normally.

Crashes inside `update` itself do **not** restart the runtime. Beryl
rescues callback crashes and contains the blast radius to the socket that
triggered them:

| Crash site | Effect |
|------------|--------|
| `init` | The connecting socket is not registered; others unaffected |
| `update` on `Join` | The join is rejected; the socket survives |
| `update` on `Message`/`Binary` | Only that topic is closed |
| `update` on `Info` | The socket is torn down |
| `update` on `Closed` | Logged; the close completes anyway |

See the [Error Handling guide](/guides/error-handling/) for details.

For channel callbacks, those rows map to `join`, `on_message`/`on_binary`,
`on_info`, and `on_terminate`. A terminate panic loses that callback's actions
but does not stop sibling-channel teardown; see
[Crash behavior](/guides/channels/#crash-behavior).

## Presence and groups

`presence.start` and `group.start` return plain OTP actors linked to the
calling process. Start them alongside `child_spec` from your long-lived
application process:

```gleam
import beryl
import beryl/group
import beryl/presence
import beryl/wire
import gleam/otp/static_supervisor

pub fn main() {
  let assert Ok(presence_actor) =
    presence.start(presence.default_config("node1"))
  let assert Ok(groups) = group.start()

  let assert Ok(#(channels, spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: init,
      update: update,
    )
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()

  // ... start the transport, run forever
}
```

Presence is a separate application-owned actor. Drive it from socket code with
`socket.PresenceTrack` / `PresenceUntrack` effects or the equivalent channel
actions. The runtime applies those mutations asynchronously and parks only the
affected socket until completion. Do not call the synchronous public presence
API directly from `init`, `update`, or a channel callback.

Both also offer `start_named` variants that register the actor under a
`process.Name` for callers integrating them into their own supervision
arrangements.

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

`beryl.stop(channels)` drains sockets gracefully: every joined topic
receives a `Closed` event, transport connections are closed, and the
runtime exits without being restarted. Calling `stop` again returns
`Error(NotRunning)`. Other operations using the handle after `stop` are
quiet no-ops.

## Production checklist

- Add the returned specification to your long-lived application supervisor.
- Start application-owned presence and group actors alongside the Beryl child.
- Configure PubSub when running more than one BEAM node.
- Configure rate limits to protect against runaway clients — see
  [Production Hardening](/guides/production-hardening/).
