---
title: Supervising Beryl
description: Place Beryl in an OTP supervision tree and understand restart, shutdown, and ownership boundaries.
---

`beryl.child_spec` does not start a socket runtime. It returns a stable
`beryl.Sockets` handle and a child specification for your application's OTP
supervisor. `channel.child_spec` returns the same pair after building the raw
router for its handler table.

That distinction determines startup order, restart behavior, and shutdown. The
handle identifies a socket system across runtime restarts, while the child
specification captures the code and configuration needed to rebuild that
system.

## Put the child specification in your application tree

The live-poll example starts Beryl under a root supervisor before starting the
Mist listener:

```gleam
let assert Ok(#(sockets, spec)) =
  channel.child_spec(
    config,
    handlers: channels.handlers(polls, clock, 60_000),
  )

let assert Ok(_root) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(spec)
  |> static_supervisor.start()
```

The first excerpt comes from
[`step_05.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/step_05.gleam).
The supervisor code comes from
[`server.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/live_poll/src/live_poll/server.gleam).
The server then passes `sockets` to `mist_transport.upgrade`.

Starting the supervisor before the listener matters. You receive the
name-backed handle when `child_spec` returns, but no runtime process exists
until a supervisor starts `spec`. Before startup, Beryl rejects connection
admission. Fire-and-forget operations through the handle do nothing rather
than sending to a missing process.

`child_spec` validates the configuration and handler table before returning
`spec`. If it returns an error, there is no child specification to add to the
supervision tree.

## Beryl owns a nested subtree

The child specification adds a Beryl subtree to your application:

```text
application supervisor
└── Beryl subtree (Transient)
    ├── router actor (Transient, significant)
    └── connection limiter (optional)

transport connection
└── socket actor (one per connection, monitored by the router)
```

The nested supervisor uses `OneForOne` with a tolerance of 3 restarts in 5
seconds. The router stores the socket actor index and topic subscriber sets.
Each socket actor stores one model, its channel instances, topic membership,
and pending protocol capabilities. Socket actors are not supervisor children.
The transport connection starts each one, and the router monitors it. When
connection limits are enabled, the limiter runs beside the router in the
subtree.

Marking the router as significant gives graceful shutdown a precise boundary.
When the router stops normally, the nested supervisor shuts down the rest of
the Beryl subtree, including the limiter. The parent application's supervisor
and sibling children keep running.

The `Transient` restart policy separates a crash from an intentional stop. An
abnormal router exit triggers a restart. A successful `beryl.stop` ends the
subtree without asking the parent supervisor to bring it back.

## The handle survives, but socket state does not

`beryl.Sockets` uses registered process names rather than storing one router
pid. A restarted router registers the same name, so application code can keep
the original handle. The child specification still holds the typed `init` and
`update` closures, or the channel router built from your handlers. The new
router starts with the same dispatch code.

The new router does not recover the old runtime state. A restart discards:

- connected socket records and per-socket models;
- channel instances and their private state;
- joined topics, pending joins, and reply capabilities;
- local subscriber maps and heartbeat timestamps.

Socket actors and transport connection processes monitor the router that
admitted them. If that router dies, the actors stop and the transports close
their WebSockets. Clients must reconnect and rejoin. This gives the replacement
router fresh socket actors, models, and channel state. Phoenix clients already
implement reconnect and rejoin behavior.

Keep shared domain state outside the Beryl runtime when it must survive a
runtime restart. The live poll stores room totals in `store.Store`, an
application-owned actor. A database or another supervised domain process can
serve the same role.

## A restart window is an unavailable window

The stable handle prevents stale-pid failures. It does not make a restart
atomic from the caller's perspective. During the interval between the old
runtime exiting and its replacement registering:

- transports reject new connection admission;
- broadcasts through the handle and notifications through socket or channel
  senders do nothing;
- `beryl.stop` can return `Error(beryl.NotRunning)`.

Returning from a broadcast or notification call does not confirm delivery. If
an event must survive a restart, store it in a durable queue or domain process
and retry after the socket reconnects. A best-effort broadcast is not a
durable message.

With connection limits enabled, the limiter survives an ordinary router
restart because `OneForOne` restarts only the failed router child. The
replacement router continues to use the same limiter.

## Restart intensity escalates repeated failures

The internal supervisor permits 3 router restarts within 5 seconds. A fourth
failure in that window exhausts its restart budget. The Beryl subtree then
exits abnormally, and your application supervisor decides whether to restart
the whole subtree.

If the parent restarts the subtree, both the router and optional limiter get
new processes. The original `Sockets` handle remains valid because the subtree
reuses its allocated names.

This escalation prevents an internal supervisor from retrying a persistent
fault forever without involving the application's supervision strategy. Logs
from the first router failure remain the place to diagnose the cause.

## Callback crashes usually do not invoke supervision

Part 5 described Beryl's scoped callback rescue. A panic in raw `update` or a
channel callback rejects a join or closes the affected topic or socket while
the socket actor continues when the scope permits. A fault outside the rescue
boundary stops that socket actor, and the router removes it. The supervisor
only responds when the router exits.

That separation avoids restarting every connection because one callback
panicked. Repeated callback panics do not consume the router's restart budget.
They appear as repeated scoped failures in logs and client behavior.

## Graceful shutdown drains the runtime

Use `beryl.stop(sockets)` when your application needs to stop only Beryl:

```gleam
case beryl.stop(sockets) {
  Ok(Nil) -> Nil
  Error(beryl.NotRunning) -> Nil
  Error(beryl.StopTimeout) -> panic as "Beryl did not stop in time"
}
```

Before it closes transport connections, the router asks each socket actor to
deliver `Closed` to every joined raw topic or call each channel's
`on_terminate`. `stop` waits for the socket actors, router, and optional
limiter to terminate. It does not stop the application supervisor or unrelated
sibling children.

`NotRunning` means the supervisor never started this handle, the system has
already stopped, or the call raced a restart window. `StopTimeout` means the
router did not acknowledge the drain or the subtree did not terminate within
the shutdown window.

Beryl does not stop application-owned dependencies such as the poll store,
timer, presence actor, or group actor. Their lifecycle belongs to the
application process or supervisor that started them. Shutting down the
application's root supervisor tears down Beryl with the rest of that tree.

## Design the ownership before opening the listener

A production startup path needs four explicit ownership decisions:

1. Build Beryl's handle and child specification.
2. Start application-owned domain actors from a long-lived application
   process or under their own supervision arrangement.
3. Add Beryl's specification to the application supervisor and start it.
4. Start the HTTP/WebSocket listener with the running `Sockets` handle.

The result has clear recovery boundaries. Beryl supervision restores the
router. Clients restore socket actors and ephemeral subscriptions by
reconnecting. Application-owned processes or storage preserve domain state.
Graceful shutdown drains socket callbacks without stopping unrelated services.

## Sources and further reading

- [Beryl supervision guide](/guides/supervision/)
- [`beryl.child_spec` and `beryl.stop`](https://github.com/tylerbutler/beryl/blob/main/packages/beryl/src/beryl.gleam)
- [Beryl runtime architecture](/architecture/runtime/)
- [Error handling](/guides/error-handling/)

## Runnable checkpoint: step 05

```sh
cd examples/live_poll && gleam run -m live_poll/step_05
```

The checkpoint creates the `Sockets` handle and specification, starts the
supervision tree, and then starts Mist on `http://localhost:8105`. Stop it with
Ctrl-C to terminate the application process and its linked tree.

Back to the [tutorial overview](/tutorial/).
