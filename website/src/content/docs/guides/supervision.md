---
title: Supervision
---

Beryl supervises itself. `beryl.start_app` has no unsupervised mode: the
runtime actor always starts under an internal supervisor, with your
`init`/`update` functions captured in the child specification. You do not
add Beryl to a supervision tree — you call `start_app` once at application
startup and hold on to the returned `Channels` handle.

## What start_app supervises

```text
beryl internal supervisor (one-for-one, 3 restarts / 5 seconds)
`- runtime actor (Transient)
```

- The **runtime actor** holds every socket's model and dispatches events to
  your `update` function. If it crashes, the supervisor restarts it with
  dispatch intact — the `init`/`update` closures live in the child
  specification, so no re-registration step exists or is needed.
- The runtime is registered under a stable name, so the `Channels` handle
  (and every transport connection holding it) keeps working across
  restarts. Sends that race a restart window degrade to quiet no-ops
  instead of crashes.
- The child is `Transient`: a graceful `beryl.stop` is final and is not
  resurrected.

After **3 restarts in 5 seconds** the internal supervisor gives up and
exits, taking the process that called `start_app` with it (they are
linked). Crash loops surface loudly instead of spinning forever.

## What a restart means for your app

A runtime restart drops **per-socket state**: models, joined topics, and
pending joins. Connected clients keep their WebSocket connection (the
transport processes are independent), but their topics are no longer
joined on the server. The Phoenix JS client handles this the same way it
handles any server restart — rejoin on the next error/timeout — and your
`init` runs again when sockets reconnect.

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

## Presence and groups

`presence.start` and `group.start` return plain OTP actors linked to the
calling process. Start them alongside `start_app` from your long-lived
application process:

```gleam
import beryl
import beryl/group
import beryl/presence
import beryl/wire

pub fn main() {
  let assert Ok(presence_actor) =
    presence.start(presence.default_config("node1"))
  let assert Ok(groups) = group.start()

  let assert Ok(channels) =
    beryl.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_presence_handle(presence_actor),
      init: init,
      update: update,
    )

  // ... start the transport, run forever
}
```

Both also offer `start_named` variants that register the actor under a
`process.Name` for callers integrating them into their own supervision
arrangements.

:::note[PubSub is not supervised]
`beryl/pubsub` is backed by Erlang's `pg` module, whose lifecycle is
managed by the BEAM runtime. Configure it with `beryl.with_pubsub`.
:::

## Startup errors

`start_app` validates its configuration and reports child startup failures
directly:

```gleam
case beryl.start_app(config, init: init, update: update) {
  Ok(channels) -> run(channels)
  Error(beryl.InvalidHeartbeatTimeout) ->
    // heartbeat_timeout_ms below 2 would silently disable eviction
    panic as "fix the heartbeat config"
  Error(beryl.RuntimeStartFailed(failure)) ->
    handle_start_failure(failure)
}
```

## Stopping

`beryl.stop(channels)` drains sockets gracefully: every joined topic
receives a `Closed` event, transport connections are closed, and the
runtime exits without being restarted. Calling `stop` again — or using the
handle after `stop` — is a quiet no-op.

## Production checklist

- Call `start_app` once, from a process that lives as long as the
  application (crash loops propagate to it by design).
- Start presence and groups before `start_app` so the config can carry the
  presence handle.
- Configure PubSub when running more than one BEAM node.
- Configure rate limits to protect against runaway clients — see
  [Production Hardening](/guides/production-hardening/).
