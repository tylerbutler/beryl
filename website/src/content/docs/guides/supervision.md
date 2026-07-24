---
title: Supervision
description: Choose between standalone start and an embedded child specification, and understand what Beryl owns.
---

Beryl now exposes two entry points for the same runtime subtree:

- `beryl.start(config, init:, update:)` starts a **standalone** Beryl subtree and returns `Result(beryl.Sockets, beryl.StartError)`.
- `beryl.child_spec(config, init:, update:)` validates the same config but returns `Result(#(beryl.Sockets, ChildSpecification(static_supervisor.Supervisor)), beryl.ConfigError)` so you can add that subtree to your own supervisor.

Both entry points build the same nested supervisor shape and run the same app-side dispatch runtime.

## Standalone start

Use `beryl.start` when your application wants a ready-to-use `beryl.Sockets` handle immediately and does not need to embed the subtree in a larger supervisor.

```gleam
import beryl
import beryl/error as beryl_error
import beryl/event as event
import beryl/wire
import gleam/io

fn init(_info: event.ConnectInfo(Nil)) -> #(Nil, List(event.Effect)) {
  #(Nil, [])
}

fn update(model: Nil, _event: event.Input(Nil)) -> event.Next(Nil, Nil) {
  event.Next(model, [])
}

pub fn main() {
  case beryl.start(beryl.config(wire.phoenix_codec()), init: init, update: update) {
    Ok(sockets) -> run(sockets)
    Error(beryl.InvalidConfig(error)) -> handle_config_error(error)
    Error(beryl.RuntimeStartFailed(failure)) ->
      io.println(beryl_error.describe_start_failure(failure))
  }
}
```

`start` validates the config first, then starts a **detached** nested supervisor. The subtree is unlinked from the caller after startup, so a later graceful `beryl.stop(sockets)` shuts down Beryl without taking the caller down too.

## Embedded start with `child_spec`

Use `beryl.child_spec` when your application already owns a root supervisor.

```gleam
import beryl
import beryl/event as event
import beryl/wire
import gleam/otp/static_supervisor

fn init(_info: event.ConnectInfo(Nil)) -> #(Nil, List(event.Effect)) {
  #(Nil, [])
}

fn update(model: Nil, _event: event.Input(Nil)) -> event.Next(Nil, Nil) {
  event.Next(model, [])
}

pub fn main() {
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: init,
      update: update,
    )

  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()

  run(sockets)
}
```

`child_spec` can fail only with `beryl.ConfigError`, because validation happens before any process starts. The returned `sockets` handle is name-backed and stable even before the tree is running; before startup, during a restart window, and after shutdown, broadcasts degrade to no-ops and new connections are refused cleanly.

## The subtree Beryl starts

Both entry points build this nested supervisor:

```text
beryl subtree (one-for-one, auto_shutdown AnySignificant)
|- runtime (Transient, significant)
`- connection limiter (optional)
```

Important properties:

- the runtime child is **Transient**, so a graceful stop is not restarted,
- the runtime child is **significant**, so a graceful runtime stop auto-shuts the whole Beryl subtree,
- the subtree restart tolerance is **3 restarts in 5 seconds**,
- the connection limiter exists only when `with_max_connections_per_ip` or `with_max_connections` is configured.

See [Runtime & Effect Interpreter](/architecture/runtime/) for the internal event and effect flow.

## What Beryl owns, and what it borrows

Beryl owns only the subtree above:

- the runtime, and
- the optional connection limiter.

Beryl **does not** start or stop these for you:

- `beryl/pubsub` handles attached with `beryl.with_pubsub`
- `beryl/presence` handles attached with `beryl.with_presence_handle`
- `beryl/group` actors started with `group.start()`

Those are borrowed dependencies. Start them in your own application code, pass their handles into `beryl.Config`, and stop or supervise them according to your own lifecycle needs.

## What `beryl.stop` does

`beryl.stop(sockets)` gracefully drains only the Beryl subtree:

- each joined topic receives `event.Closed(topic, reason)`,
- leftover tracked presence for those topics is cleaned up,
- terminal frames are sent to clients,
- transport connections are closed,
- the runtime and its optional limiter are awaited.

It does **not** stop your root supervisor, your PubSub instance, your presence actor, or your groups actor.

The return type is `Result(Nil, beryl.StopError)`:

- `Ok(Nil)` — the subtree stopped cleanly
- `Error(beryl.NotRunning)` — the handle was never started, is mid-restart, or was already stopped
- `Error(beryl.StopTimeout)` — the runtime did not acknowledge shutdown within 5000 ms

## Crash and restart semantics

A runtime crash is different from a graceful stop.

After a crash:

- the supervisor restarts the runtime under the same registered name,
- the `beryl.Sockets` handle continues to work for **new** connections and broadcasts,
- all in-memory per-socket state is gone: models, joined topics, and rate-limit buckets are rebuilt from scratch,
- existing WebSocket connections close, because the transport monitors the runtime that accepted them and tears the socket down when that runtime dies.

In other words: the handle is stable, but live socket state is not.

## Production checklist

- Pick `beryl.start` for a standalone subtree or `beryl.child_spec` for an application-owned supervision tree.
- Start PubSub, presence, and groups separately before attaching their handles to Beryl config.
- Treat runtime crashes as loss of all live socket state; design reconnect and rejoin flows accordingly.
- Call `beryl.stop` only when you want to drain and stop the Beryl subtree itself.
- Configure connection limits and rate limits before exposing the socket publicly.
