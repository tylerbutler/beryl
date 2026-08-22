# Supervising Beryl

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
[`step_05.gleam`](../../examples/blog_series/src/blog_series/step_05.gleam);
the supervisor code comes from
[`server.gleam`](../../examples/blog_series/src/blog_series/server.gleam).
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
    ├── runtime actor (Transient, significant)
    └── connection limiter (optional)
```

The nested supervisor uses `OneForOne` with a tolerance of 3 restarts in 5
seconds. The runtime actor stores socket models, channel instances, topic
membership, and pending protocol capabilities. When connection limits are
enabled, the limiter runs as a sibling in the same subtree.

Marking the runtime as significant gives graceful shutdown a precise boundary.
When the runtime stops normally, the nested supervisor shuts down the rest of
the Beryl subtree, including the limiter. The parent application's supervisor
and sibling children keep running.

The `Transient` restart policy separates a crash from an intentional stop. An
abnormal runtime exit triggers a restart. A successful `beryl.stop` ends the
subtree without asking the parent supervisor to bring it back.

## The handle survives; socket state does not

`beryl.Sockets` uses registered process names rather than storing one runtime
pid. A restarted runtime registers the same name, so application code can keep
the original handle. The child specification still holds the typed `init` and
`update` closures, or the channel router built from your handlers. The new
runtime starts with the same dispatch code.

The new runtime does not recover the old runtime's memory. A restart discards:

- connected socket records and per-socket models;
- channel instances and their private state;
- joined topics, pending joins, and reply capabilities;
- local subscriber maps and heartbeat timestamps.

Transport connection processes monitor the runtime that admitted them. If
that runtime dies, they close their WebSockets. Clients must reconnect and
rejoin, which gives the replacement runtime fresh models and channel state.
Phoenix clients already implement reconnect and rejoin behavior.

Keep shared domain state outside the Beryl runtime when it must survive a
runtime restart. The live poll stores room totals in `store.Store`, an
application-owned actor. A database or another supervised domain process can
serve the same role.

## A restart window is an unavailable window

The stable handle prevents stale-pid failures; it does not make a restart
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

With connection limits enabled, the limiter survives an ordinary runtime
restart because `OneForOne` restarts only the failed runtime child. The
replacement runtime continues to use the same limiter.

## Restart intensity escalates repeated failures

The internal supervisor permits 3 runtime restarts within 5 seconds. A fourth
failure in that window exhausts its restart budget. The Beryl subtree then
exits abnormally, and your application supervisor decides whether to restart
the whole subtree.

If the parent restarts the subtree, both the runtime and optional limiter get
new processes. The original `Sockets` handle remains valid because the subtree
reuses its allocated names.

This escalation prevents an internal supervisor from retrying a persistent
fault forever without involving the application's supervision strategy. Logs
from the first runtime failure remain the place to diagnose the cause.

## Callback crashes usually do not invoke supervision

Part 5 described Beryl's scoped callback rescue. A panic in raw `update` or a
channel callback rejects a join or closes the affected topic or socket while
the runtime continues. The supervisor only responds when the runtime process
exits.

That separation avoids restarting every connection because one application's
callback panicked. It also means repeated callback panics will not consume the
runtime's restart budget. They appear as repeated scoped failures in logs and
client behavior instead.

## Graceful shutdown drains the runtime

Use `beryl.stop(sockets)` when your application needs to stop only Beryl:

```gleam
case beryl.stop(sockets) {
  Ok(Nil) -> Nil
  Error(beryl.NotRunning) -> Nil
  Error(beryl.StopTimeout) -> panic as "Beryl did not stop in time"
}
```

The runtime delivers `Closed` to each joined raw topic, or calls each channel's
`on_terminate`, before closing transport connections. `stop` waits for the
runtime and optional limiter to terminate. It leaves the application
supervisor and unrelated sibling children alone.

`NotRunning` means the supervisor never started this handle, the system has
already stopped, or the call raced a restart window. `StopTimeout` means the
runtime did not acknowledge the drain or the subtree did not terminate within
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

The result has clear recovery boundaries. Beryl supervision restores dispatch.
Clients restore ephemeral subscriptions by reconnecting. Application-owned
processes or storage preserve domain state. Graceful shutdown drains socket
callbacks without stopping unrelated services.

## Sources and further reading

- [Beryl supervision guide](../../website/src/content/docs/guides/supervision.md)
- [`beryl.child_spec` and `beryl.stop`](../../packages/beryl/src/beryl.gleam)
- [Beryl runtime architecture](../../website/src/content/docs/architecture/runtime.md)
- [Error handling](../../website/src/content/docs/guides/error-handling.md)

## Runnable checkpoint: step 05

```sh
cd examples/blog_series && gleam run -m blog_series/step_05
```

The checkpoint creates the `Sockets` handle and specification, starts the
supervision tree, and then starts Mist on <http://localhost:8105>. Stop it with
Ctrl-C to terminate the application process and its linked tree.

Index: [Beryl introduction](README.md).
