---
title: Supervising Beryl
description: Start Beryl under an OTP supervisor and control restarts, shutdown, and process ownership.
---

`beryl.child_spec` does not start anything. It returns two values. The first is
a `beryl.Sockets` handle. The second is a child specification. A child
specification tells an OTP supervisor how to start and restart a process. Your
application adds it to its own supervisor. `channel.child_spec` returns the same
two values. It builds the raw router from your handlers first.

This split controls three things: what starts first, what happens after a crash,
and what happens at shutdown. The handle names one socket system. It stays valid
when the runtime restarts. The child specification holds the code and
configuration the supervisor needs to build that system again.

## Put the child specification in your application tree

The live-poll example starts Beryl under a root supervisor. Then it starts the
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

The order matters. You get the handle when `child_spec` returns. But no runtime
process exists until a supervisor starts `spec`. Before that, Beryl refuses new
connections. Calls through the handle that do not wait for a reply, such as a
broadcast, do nothing. They do not crash because the process is missing.

`child_spec` checks the configuration and the handler list before it returns
`spec`. If it returns an error, there is nothing to add to the supervisor.

## Processes started by beryl

The child specification adds a Beryl subtree to your application:

```text
application supervisor
└── Beryl subtree (Transient)
    ├── router actor (Transient, significant)
    └── connection limiter (optional)

transport connection
└── socket actor (one per connection, monitored by the router)
```

The Beryl subtree has its own supervisor. That supervisor uses `OneForOne`. It
allows 3 restarts in 5 seconds. The router actor keeps the list of socket
actors and the set of subscribers for each topic. Each socket actor keeps one
model, its channel instances, its joined topics, and its pending reply
capabilities. Socket actors are not children of the supervisor. The transport
connection starts each one, and the router monitors it. If you enable
connection limits, the limiter runs next to the router.

The router is marked as *significant*. When
the router stops normally, the Beryl supervisor stops the rest of the subtree,
including the limiter. Your application supervisor and its other children keep
running.

The `Transient` restart policy tells a crash and a normal stop apart. If the
router crashes, the supervisor restarts it. If `beryl.stop` succeeds, the
subtree ends and the parent supervisor does not restart it.

## The handle survives a restart. Socket state does not.

`beryl.Sockets` holds registered process names, not a process id. A restarted
router registers the same names. Your code can keep the same handle. The child
specification still holds your typed `init` and `update` functions, or the
channel router built from your handlers. The new router runs the same code.

The new router does not get the old state back. A restart discards:

- connected socket records and their models;
- channel instances and their private state;
- joined topics, pending joins, and reply capabilities;
- local subscriber maps and heartbeat timestamps.

Socket actors and transport connections monitor the router that admitted them.
If that router dies, the socket actors stop and the transports close their
WebSockets. Clients must reconnect and join again. The new router then gets
fresh socket actors, models, and channel state. Phoenix clients already know
how to reconnect and rejoin.

If state must survive a restart, keep it outside the Beryl runtime. The live
poll keeps room totals in `store.Store`, an actor your application owns. A
database or another supervised process works the same way.

## Calls can fail while the router restarts

The stable handle means you never hold a dead process id. It does not make a
restart invisible. Between the old runtime exiting and the new one registering:

- transports refuse new connections;
- broadcasts through the handle do nothing, and so do notifications through
  socket or channel senders;
- `beryl.stop` can return `Error(beryl.NotRunning)`.

When a broadcast or notification call returns, that does not mean the message
arrived. If an event must survive a restart, store it in a durable queue or a
domain process. Send it again after the socket reconnects. A best-effort
broadcast is not a durable message.

If you enable connection limits, the limiter survives a normal router restart.
`OneForOne` restarts only the router. The new router uses the same limiter.

## Repeated router failures stop the beryl subtree

The Beryl supervisor allows 3 router restarts in 5 seconds. A fourth failure in
that window uses up the budget. The whole Beryl subtree then exits with an
error. Your application supervisor decides what to do next. It may restart the
subtree, or it may give up.

If the parent restarts the subtree, the router and the optional limiter both get
new processes. The original `Sockets` handle still works. The subtree registers
the same names again.

This rule stops the Beryl supervisor from retrying the same fault forever. Your
own supervision strategy gets a say. To find the cause, read the logs from the
first router failure.

## A callback crash usually does not reach the supervisor

Chapter 5 described how Beryl catches panics in callbacks. A panic in raw
`update` or in a channel callback has a small effect. It rejects the join, or
it closes the topic or socket that caused it. The socket actor keeps running
when the scope allows. A fault outside that catch stops the socket actor, and
the router removes it. The supervisor acts only when the router itself exits.

This keeps one bad callback from restarting every connection. Repeated callback
panics do not use the router's restart budget. You see them as repeated small
failures in logs and in client behavior.

## Graceful shutdown drains the runtime

Use `beryl.stop(sockets)` when your application must stop only Beryl:

```gleam
case beryl.stop(sockets) {
  Ok(Nil) -> Nil
  Error(beryl.NotRunning) -> Nil
  Error(beryl.StopTimeout) -> panic as "Beryl did not stop in time"
}
```

First, the router asks each socket actor to clean up. In raw dispatch, each
joined topic gets `Closed`. In `beryl/channel`, each channel runs
`on_terminate`. Then the router closes the transport connections. `stop` waits
for the socket actors, the router, and the optional limiter to end. It does not
stop your application supervisor or its other children.

`NotRunning` means one of three things: the supervisor never started this
handle, the system already stopped, or the call happened during a restart
window. `StopTimeout` means the router did not confirm the drain, or the
subtree did not end before the deadline.

Beryl does not stop processes your application owns. The poll store, the timer,
the presence actor, and the group actor all belong to the process or supervisor
that started them. When your root supervisor shuts down, it stops Beryl with the
rest of the tree.

## Start processes before the WebSocket listener

A production startup path makes four decisions, in this order:

1. Build Beryl's handle and child specification.
2. Start your domain actors from a long-lived application process, or under
   their own supervisor.
3. Add Beryl's specification to your application supervisor and start it.
4. Start the HTTP/WebSocket listener with the running `Sockets` handle.

Each part then has a clear recovery path. Beryl's supervisor restores the
router. Clients restore socket actors and subscriptions when they reconnect.
Your own processes or storage keep the domain state. Graceful shutdown drains
socket callbacks without stopping unrelated services.

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
Ctrl-C to end the application process and its linked tree.

Back to the [tutorial overview](/tutorial/).
