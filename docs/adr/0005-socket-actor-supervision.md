# ADR 0005: Socket actor supervision

## Status

Accepted (2026-08-28).

This ADR follows
[ADR 0004](0004-channel-process-fault-boundaries.md). ADR 0004 assigns one
actor to each socket and one worker to each accepted channel topic. It selects
the process boundaries. This ADR considers whether an OTP factory supervisor
should start and own the socket actors.

## Context

beryl uses supervisors for durable services and monitors for connection-scoped
processes.

The application supervisor owns a beryl subtree. That subtree contains the
router actor and the optional connection limiter. The router uses a stable
registered name and a `Transient` restart policy.

The transport connection starts one socket actor during admission. The router
and socket actor monitor each other:

- If the socket actor stops, the router removes its topic subscriptions,
  presence data, and actor-table entry. It also asks the transport to close
  the WebSocket.
- If the router stops, the socket actor stops. The transport also monitors the
  router and closes the WebSocket.

For `beryl/channel`, each socket actor starts a linked factory supervisor. That
supervisor starts one `Temporary` topic worker for each accepted join. The
socket actor monitors each worker. If a worker stops unexpectedly, the socket
actor closes its topic with `phx_error`. The client must rejoin.

This topology gives each process a failure owner, but socket actors do not
appear as children in an OTP supervision tree. The supervision guide calls
this a supervised system because an OTP supervisor owns the durable runtime
and monitors cover the connection processes. That wording can imply that OTP
supervisors own every actor.

### Restart is not recovery for connection state

A socket actor owns ephemeral state:

- the application model;
- accepted joins and topic subscriptions;
- pending join and reply refs;
- heartbeat and rate-limit state;
- presence refs;
- transport send and close functions.

A supervisor cannot reconstruct this state after a crash. A new socket actor
would need to repeat connection initialization, authentication, and each join.
It cannot do that without a new client handshake. A transparent restart could
process messages with missing or stale state.

A topic worker has the same constraint at a smaller scope. It owns one join's
channel state and authorization result. The client must rejoin after that
worker stops.

The correct restart policies are therefore:

| Process | Restart policy | Recovery |
|---|---|---|
| router | `Transient` | restart with no connections |
| socket factory supervisor | `Permanent` | restore socket-start capacity |
| socket actor | `Temporary` | close the WebSocket and reconnect |
| topic worker supervisor | owned by the socket actor | stop with the socket |
| topic worker | `Temporary` | close the topic and rejoin |

Adding a socket factory supervisor would standardize ownership and shutdown.
It would not make socket actors restartable.

## Decision drivers

The design must preserve these properties:

- Connection setup on different sockets can run concurrently.
- A slow or panicking application `init` does not delay other connections.
- The router keeps its admission operation bounded and does not wait for app
  callbacks.
- A socket actor cannot register with a router that restarted during
  admission.
- Router failure closes all connections from that router generation.
- Socket failure removes all router and presence state for that socket.
- Graceful shutdown runs `Closed` and `on_terminate` before it kills a stuck
  process.
- Socket and topic state never restart without a new client handshake.

The design should also make ownership clear in OTP inspection tools and avoid
custom lifecycle code when an OTP primitive supplies the same behavior.

## Options

### 1. Keep transport-started socket actors

Each transport connection calls `runtime.start_socket_actor`. It then submits
the actor to the router through the admission protocol. The router monitors
the actor after it inserts the actor into its table.

The socket actor monitors the exact router PID that the transport captured
before admission. If that router stops, the socket actor stops. This prevents
an actor from attaching to a replacement router with stale admission state.

Advantages:

- Socket actors start in parallel from independent transport processes.
- Application `init` for one socket cannot block another socket start.
- The router performs a bounded registration step and does not start
  processes.
- The design adds no supervisor child table beside the router actor table.
- The current admission, shutdown, and crash-sweep behavior already has test
  coverage.

Costs:

- OTP tools do not show socket actors under a common supervisor.
- beryl implements some ownership and shutdown behavior with monitors.
- The phrase "supervised socket actor" needs qualification because no OTP
  supervisor owns that actor.

### 2. Use one shared socket factory supervisor

The beryl subtree adds a named factory supervisor. The factory uses one child
template for all socket actors and a `Temporary` restart policy.

```text
application supervisor
`- beryl subtree
   |- router actor (Transient)
   |- socket factory supervisor (Permanent)
   |  |- socket actor A (Temporary)
   |  |  `- topic worker supervisor
   |  |- socket actor B (Temporary)
   |  |  `- topic worker supervisor
   |  `- socket actor C (Temporary)
   `- connection limiter (optional)
```

During admission, the transport captures the current router PID. It calls
`factory_supervisor.start_child` with that PID, the connection data, and the
transport functions. The child template captures the generic `init`, `update`,
and channel-worker functions in closures.

The router must still monitor each socket actor. The factory owns process
lifetime, but it lacks the socket's router indexes, presence refs, and
transport closer. The router monitor still drives domain cleanup.

The socket actor must still monitor the router. If the router restarts, old
socket actors must stop instead of attaching to the new router generation.

Advantages:

- OTP tools show all socket actors under one known supervisor.
- OTP supplies child ownership, shutdown timeouts, and forced termination.
- The factory gives connection metrics and child counts a standard location.
- A child belongs to the factory before router registration starts.

Costs:

- The factory and router both store per-socket process metadata.
- Each connection start adds a request and response through the factory.
- One factory mailbox receives all socket start requests.
- The existing router monitors and cleanup paths remain necessary.
- Graceful shutdown must drain sockets before the parent stops the factory.

#### Startup serialization

`factory_supervisor.start_child` is synchronous. The supervisor waits for the
socket actor's start result before it handles the next start request.

The current socket actor does not run application `init` during this start
operation. It starts its topic worker supervisor, constructs empty state, and
returns its subject and PID. The router later forwards `AdmitSocket`. The
socket actor then runs application `init` and answers the transport directly.
Application initialization already runs outside the router and socket-start
critical paths.

A shared factory would serialize only the small actor-start operation. It
would not serialize application `init`. Connection bursts can still contend
on the factory mailbox, so benchmarks must measure this cost.

### 3. Use a shared factory with explicit two-phase admission

The factory starts each socket actor in a `Booting` phase. The actor returns
from startup before it runs application `init`. The existing admission
protocol then performs phase two:

```text
phase 1: process startup
  transport captures the current router PID
  -> socket factory starts a Temporary socket actor
  -> actor starts its per-socket topic factory
  -> actor returns its subject and PID

phase 2: admission and application initialization
  transport submits the actor to the captured router
  -> router validates the owner and admission token
  -> router monitors and indexes the actor
  -> router sends AdmitSocket to the actor
  -> actor runs application init
  -> actor answers the transport
  -> actor enters Active or stops
```

The current implementation already separates actor startup from application
`init`. This option keeps that behavior and makes the phase boundary explicit.

The socket actor can represent the phase in its state:

```gleam
type SocketPhase(model) {
  Booting
  Active(model)
  Closing
}
```

The phase must handle these races:

- the transport closes while `init` runs;
- the router stops before registration;
- admission times out after the actor starts;
- beryl shutdown starts during `Booting`;
- `init` succeeds after the transport cancels admission.

Advantages:

- Socket actors appear in the supervision tree.
- Application initialization does not hold the factory start call.
- The design preserves parallel initialization across connections.
- The phase model makes pre-admission behavior explicit.

Costs:

- The factory adds one serialized start request for each connection.
- Admission becomes an explicit state machine.
- A started child can exist without an admitted socket.
- Shutdown and timeout paths must handle both `Booting` and `Active`.
- The change needs new integration and race tests.

### 4. Add one supervisor for each socket session

A shared factory can start a temporary supervisor for each socket. That
session supervisor can own the socket actor and its topic worker supervisor as
siblings.

This topology makes the socket session an explicit subtree, but it adds one
process for each connection. Raw dispatch would gain a session supervisor even
though it has no topic workers. The shared factory can still serialize session
startup if the nested supervisor waits for socket initialization.

This option gives clearer diagrams but does not improve recovery. The socket
actor and topic workers must remain `Temporary`.

## Decision

Adopt option 3: add one shared socket factory supervisor and use explicit
two-phase admission.

The nested beryl supervisor will own these children:

```text
beryl internal supervisor
|- router actor (Transient, significant)
|- socket factory supervisor (Permanent)
|  `- socket actors (Temporary)
`- connection limiter (optional)
```

Each socket actor will continue to own its per-socket topic worker supervisor.
Topic workers will remain `Temporary`.

The socket factory child template will capture the runtime configuration,
`init`, `update`, and optional topic-worker opener. The per-connection start
argument will contain the captured router PID and the connection-specific
transport data.

Phase one will start the actor and return its subject and PID. It will not run
application `init`. Phase two will use the existing admission token and
owner check. The router will monitor and index the actor before it forwards
`AdmitSocket`. The actor will run application `init` and answer the transport.

The `Booting` phase will be bounded. A cancelled admission stops the actor
through the existing `StopSocketActor` cast. An actor whose transport process
dies before it reaches the router receives no such cast, so the actor also
stops itself at a boot deadline. This keeps a never-admitted child from
accumulating under the factory. The deadline is read between turns only, so it
never interrupts a slow application `init`.

Socket actors will remain `Temporary`. The supervisor will not restart socket
or topic state without a new client handshake. If a socket actor stops, the
router monitor will still remove routing and presence state. If the router
stops, the socket actor will stop and the client will reconnect.

The router monitor remains necessary because the supervisor does not own the
router's domain cleanup. The transport monitor also remains necessary because
it closes the WebSocket when the admitting router generation stops.

Graceful `beryl.stop` must drain socket actors before the internal supervisor
stops the socket factory. The factory shutdown timeout is a final safeguard
for actors that do not finish the drain.

### Factory failure

The factory owns and links every socket actor it starts. If the factory
fails, all of its socket actors stop with it, in both the `Booting` and the
`Active` phase. The router monitors each admitted actor, so it sweeps their
topic index entries and presence data and calls their transport closers. The
clients see closed connections and reconnect.

The factory is a `Permanent` child, so the nested beryl supervisor restarts it
under the same registered name. The router is not restarted by that failure
and keeps its generation. Transports reach the replacement factory through its
name rather than a captured PID, so new connections are admitted as soon as
the replacement is registered.

## Consequences

- OTP tools can list socket actors under one known supervisor.
- The socket factory provides standard child ownership and forced shutdown.
- Application `init` remains concurrent across socket actors.
- The factory serializes only the actor-start operation.
- The router keeps its bounded admission turn and does not wait for `init`.
- The router and socket actors retain their mutual monitors.
- The transport retains its monitor of the admitting router generation.
- Socket actors and topic workers do not restart with incomplete state.
- The factory and router both retain per-socket process metadata.
- Admission gains explicit `Booting`, `Active`, and `Closing` phases.
- Shutdown must preserve drain-before-factory-stop order.
- A factory failure closes every connection the factory owned. The router
  sweep and the `Permanent` restart restore service without a router restart.

The new factory improves OTP ownership and inspection. It does not replace
protocol-level monitors or client reconnect and rejoin recovery.

## Implementation requirements

The implementation must:

- add a stable name and handle for the socket factory;
- add the factory as a `Permanent` child of the nested beryl supervisor;
- configure socket actors as `Temporary` children;
- keep application `init` out of the child start operation;
- preserve the exact router PID and admission-token checks;
- keep the router monitor for index, presence, and transport cleanup;
- keep the socket actor monitor of the router;
- drain socket actors before stopping the socket factory;
- reject or stop a `Booting` actor after admission cancellation;
- stop all per-socket topic workers when their socket actor stops.

The implementation must add integration tests for:

- transport close during `Booting`;
- router failure before and after router registration;
- admission timeout before and after `init` completes;
- socket factory failure with active connections;
- graceful shutdown with booting and active sockets;
- socket and topic worker crashes;
- reconnect and rejoin after each temporary child stops.

## Performance validation

Compare the current direct-start design with the two-phase factory design.
Measure:

- connection starts per second;
- p50, p95, and p99 admission latency;
- performance when one `init` uses its full timeout;
- reconnect-storm behavior;
- memory per active socket;
- graceful shutdown time with active sockets and topics;
- cleanup after router, socket actor, and topic worker failures.

The factory design is acceptable only if a slow `init` does not increase
admission latency for unrelated sockets. Burst-start throughput must not
regress by more than 10 percent at the expected deployment scale. The pull
request must report the test scale, Erlang version, scheduler count, and raw
results.

### Results

The implementation was compared with the direct-start design on Erlang
27.2.1 with 12 schedulers. Both variants used the Mist transport and the k6
`connection-rate` profile at 2,000 connections per second for 30 seconds.
Each variant ran three times after a protocol warm-up and a 65-second
cool-down between runs.

| Design and run | Starts per second | p50 | p95 | p99 | Dropped | Errors |
|---|---:|---:|---:|---:|---:|---:|
| Direct 1 | 1,999.86 | 1 ms | 4 ms | 9 ms | 0 | 0 |
| Direct 2 | 1,999.70 | 1 ms | 4 ms | 10 ms | 0 | 0 |
| Direct 3 | 1,999.29 | 1 ms | 2 ms | 7 ms | 0 | 0 |
| Factory 1 | 1,998.11 | 1 ms | 15 ms | 56 ms | 0 | 0 |
| Factory 2 | 1,999.90 | 1 ms | 2 ms | 4 ms | 0 | 0 |
| Factory 3 | 1,999.90 | 0 ms | 2 ms | 5 ms | 0 | 0 |

Median throughput was 1,999.70 starts per second for direct startup and
1,999.90 for factory startup. Factory throughput was 100.01 percent of the
direct-start result, so it passed the 90 percent acceptance threshold. The
factory medians were 1 ms at p50, 2 ms at p95, and 5 ms at p99, with no
dropped iterations or unexpected errors.

A higher-rate probe was excluded because other processes loaded the shared
host during one variant. Capacity above 2,000 starts per second requires a
separate comparison on an isolated host.

## Sources

- [ADR 0004: Socket and channel process fault boundaries](0004-channel-process-fault-boundaries.md)
- [Gleam OTP factory supervisors](https://hexdocs.pm/gleam_otp/gleam/otp/factory_supervisor.html)
- [Erlang/OTP supervision principles](https://www.erlang.org/doc/system/sup_princ.html)
- [Erlang supervisor behavior](https://www.erlang.org/doc/apps/stdlib/supervisor.html)
