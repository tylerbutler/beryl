# ADR 0004: Socket and channel process fault boundaries

## Status

Accepted (2026-08-26). Proposed 2026-08-17.

This ADR records an architectural question that ADRs
[0001](0001-type-erased-channel-registry.md),
[0002](0002-app-side-dispatch.md), and
[0003](0003-layered-channel-api.md) did not evaluate.

## Context

beryl currently runs one supervised runtime actor per socket system. That
actor owns every connected socket's raw model, every joined channel's sealed
state, protocol capabilities, topic membership, and effect interpretation.
Application callbacks run in that actor.

The runtime rescues callback panics instead of letting them terminate the
actor. It converts each failure into a protocol-scoped outcome:

| Failure | Current outcome |
|---|---|
| raw `init` | refuse socket registration |
| raw `Join` or channel `join` | reject the join |
| topic-scoped message or binary callback | close the topic |
| raw `Info` or channel `on_info` | close the socket |
| close or termination callback | log the panic and continue cleanup |

This policy prevents one application callback from destroying every socket
stored in the shared runtime. It resembles Erlang's `gen_event`, where one
event manager hosts several callback handlers and removes a failing handler
without terminating the manager.

It differs from the more common OTP fault-isolation model. A `gen_server`
callback runs inside the process whose state it owns. An unhandled panic
terminates that process, and a supervisor applies the child's restart policy.
Phoenix Channels also creates one channel server process for each client and
joined topic. Process boundaries supply fault containment instead of a rescue
layer inside one shared process.

Supervision does not imply transparent restart. A failed socket or channel
process has lost ephemeral state, authorization results, and protocol
capabilities. Restarting it without a new client join could recreate state the
client did not negotiate and repeat join-time work. A temporary child followed
by client reconnect or rejoin may be safer than restarting that child.

### Why earlier ADRs did not resolve this question

The existing ADRs concentrated on type representation and dispatch ownership:

- ADR 0001 compared application message unions, app-side dispatch, and
  closure-captured type erasure for a library-owned channel registry.
- ADR 0002 moved routing into one application `update` function and relied on
  one runtime actor turn to preserve effect order.
- ADR 0003 rebuilt channel ergonomics as values and sealed closures layered
  strictly on ADR 0002's public raw-dispatch API.

The coordinator removed by ADR 0002 also stored all joined channel instances
as values inside one actor. ADR 0003 therefore inherited an established
process topology when it chose to remain a value-level layer over the core.

The issue tracker did raise the fault-boundary question:

- [#228](https://github.com/tylerbutler/beryl/issues/228) documented why the
  shared coordinator required callback rescue and asked ADR 0002 either to
  introduce process boundaries or to decide explicitly against them.
- [#229](https://github.com/tylerbutler/beryl/issues/229) proposed one
  supervised process per joined channel if the old channel-module API
  survived. The issue closed when ADR 0002 removed that API and coordinator.
- [#334](https://github.com/tylerbutler/beryl/issues/334) now tracks a
  process-per-socket design that preserves a stable router and the current
  public API.
- [#337](https://github.com/tylerbutler/beryl/issues/337) tracks a new
  process-per-channel prototype against the restored channel layer.

ADR 0003 later restored a channel API as a layer over raw dispatch. That does
not revive #229's coordinator-specific implementation, but it makes the
process-per-channel fault boundary relevant again.

None of the accepted ADRs compares one shared runtime actor with one process
per socket or one process per joined channel. The current topology is
therefore an inherited implementation decision rather than a recorded choice
between these alternatives.

## Question

This ADR must decide which process boundary owns application state and
executes application callbacks.

The answer must cover both public programming models:

- raw dispatch, where one model spans a socket and all its topics;
- `beryl/channel`, where each accepted topic has private state and callbacks.

It must also preserve beryl's existing protocol and type-safety contracts:

- Phoenix-compatible text and binary framing;
- exact `JoinRef` and `ReplyRef` capability identity;
- observable action and effect ordering;
- generation-safe typed senders;
- no unchecked coercions in socket or channel dispatch;
- scoped presence ordering;
- connection admission and ownership rules;
- PubSub fan-out;
- graceful subtree shutdown.

## Options

### 1. Keep one shared runtime actor

The current runtime remains the only process that owns socket and channel
state. It continues rescuing application callback panics and translating them
into join, topic, or socket closure.

Advantages:

- preserves the current implementation and public behavior;
- keeps protocol state and effect ordering in one mailbox;
- stores heterogeneous channel states through the existing closure-sealed
  representation;
- avoids a process and mailbox per socket or topic;
- can scope some failures more narrowly than a process-per-socket design.

Costs:

- application callbacks do not use BEAM process boundaries for isolation;
- a blocking callback delays unrelated sockets in the same runtime;
- rescue policy becomes part of beryl's correctness surface;
- runtime-wide state and callback execution share one throughput bottleneck;
- Phoenix-shaped APIs have different server-side failure semantics from
  Phoenix even though the wire protocol matches.

This design has OTP precedent in `gen_event`, but it is not the default fault
model of actors such as `gen_server`.

### 2. Use one process per socket

Each admitted WebSocket gets a temporary actor. This actor owns the raw model,
protocol capabilities, and joined topics. For the channel layer, it also owns
all channel instances on that socket. A smaller system process would retain
global configuration, connection admission, PubSub integration, and external
`Sockets` operations.

An uncaught callback panic would terminate one socket actor. The transport
would close, and the client would reconnect and rebuild its state through
`init` and joins.

Advantages:

- matches raw dispatch's existing state boundary;
- isolates callback latency and crashes to one client connection;
- keeps all events and effects for one socket in one mailbox;
- requires fewer processes than process-per-channel;
- uses client reconnect as the recovery mechanism for ephemeral state.

Costs:

- one channel callback panic closes every topic on that socket;
- channel state remains value-level rather than process-isolated;
- global broadcasts and PubSub fan-out must address many socket actors;
- connection shutdown must coordinate the transport and socket actor;
- the process count grows with concurrent connections.

This option gives raw dispatch a natural fault boundary. The boundary is
coarser than the Phoenix Channels boundary. It is also coarser than beryl's
current topic-scoped rescue for message and binary callbacks.

### 3. Use one process per socket and one process per channel

Each socket gets a session actor that owns connection-level protocol state.
Each accepted topic gets a temporary topic worker under an OTP factory
supervisor. The worker owns the channel's sealed state and invokes its
callbacks.

A possible topology is:

```text
application supervisor
└── beryl subtree
    ├── control plane and PubSub integration
    ├── connection limiter (optional)
    ├── socket session supervisor
    │   ├── socket session A
    │   └── socket session B
    └── channel factory supervisor
        ├── socket A / poll:demo
        ├── socket A / guide:intro
        └── socket B / poll:demo
```

The socket session would route a joined topic's events to its worker. A worker
would return an action batch stamped with the socket id, topic, join
generation, and event sequence. The session would reject stale batches before
applying actions to protocol state.

Handler registration could preserve heterogeneous state without coercion by
producing a non-generic child-start closure. That closure would capture the
concrete state and info types. It would start the typed worker and return a
sealed `ChannelRef`. The operations of `ChannelRef` hide the worker's subject
type. This design extends ADR 0003's closure-sealing technique across a process
boundary. It does not replace the technique with `Dynamic`.

The session would monitor each worker. An abnormal worker exit would invalidate
its sender, close that topic, and tell the client to rejoin. A socket close
would terminate all workers owned by that session.

Advantages:

- aligns channel state, callback execution, and fault isolation;
- isolates a callback panic or long-running callback to one joined topic;
- resembles Phoenix's process-per-client-and-topic model;
- lets OTP monitors drive cleanup instead of relying only on rescued
  exceptions;
- gives topic workers independent mailboxes for typed server messages.

Costs:

- introduces the most processes, monitors, and messages;
- splits protocol ordering across session and channel mailboxes;
- requires a safe asynchronous join handshake;
- must prevent stale worker results from using pending refs or acting on a
  replacement join;
- must retain closure-sealed heterogeneous types across process handles;
- complicates presence operations that pause one ordered action list;
- makes cross-topic raw effects and socket-wide stop coordination more
  expensive;
- creates different natural process models for raw dispatch and channels.

Implementing this design requires more than a small change to callback error
handling. It changes the runtime's ownership and sequencing model.

### Sequencing decisions the prototype must make

A process prototype must decide the following points before comparing its
behavior with the current runtime:

- State whether a socket session permits only one in-flight callback. This
  choice preserves current socket-wide sequencing, and it allows one slow
  channel to delay its siblings.
- State whether topic workers can run concurrently. If so, state which
  ordering guarantees remain between actions from different topics on one
  WebSocket.
- State whether `join` runs while the worker starts. As an alternative,
  state whether the worker reports its decision through an asynchronous
  handshake.
- Define how the session applies backpressure when a worker mailbox grows or
  its own pending action-batch queue grows.
- Define which process owns presence suspension state while one channel
  waits for an asynchronous presence mutation.

The implementation must state these semantics explicitly. Process isolation
alone does not preserve the ordering contract.

### 4. Spawn a process for each callback invocation

The runtime could keep state centrally and execute each callback in a short
worker process.

This option is not a candidate for adoption. It would copy state into another
process for each event and require a result handshake. It would also add
timeout and cancellation semantics. The runtime would still decide whether a
late result is valid. Persistent socket or topic workers provide a clearer
ownership boundary.

## Restart policy and protocol recovery

If the project adopts option 2 or option 3, prototype socket and channel
workers initially as `Temporary` children.

An automatic restart cannot recover the crashed process's heap. Running
`init` or `join` again without a client request may:

- repeat authorization or accounting work;
- emit duplicate join-time actions;
- create new refs while the client retains old ones;
- restore default state that contradicts domain state;
- accept a topic the client has already left.

The protocol already provides a reconstruction boundary. A socket reconnect
runs raw `init` again. A topic rejoin runs channel `join` again with a new
generation and new capabilities. Supervision should contain and observe the
failed process. The client protocol should recreate ephemeral session state.

A future design could support automatic restart only for explicitly
reconstructable workers with a documented state source and replay contract.
That is outside this ADR.

## Required prototypes

This ADR remains proposed until two implementation spikes exist.

### Prototype A: process per socket

Tracked by [#334](https://github.com/tylerbutler/beryl/issues/334).

Build the smallest runtime path that can:

- admit a transport connection into a temporary socket actor;
- run raw `init` and `update` in that actor;
- preserve ordered effects for one socket;
- route external broadcasts and PubSub messages;
- close the transport when the socket actor exits;
- stop all socket actors during graceful beryl shutdown.

### Prototype B: process per channel

Tracked by [#337](https://github.com/tylerbutler/beryl/issues/337).

Build on a socket session actor and demonstrate:

- factory-supervised temporary topic workers;
- join success, rejection, panic, and timeout;
- typed `channel.Sender` delivery to the correct worker generation;
- ordered action batches returned to the session;
- worker crash followed by topic close and client rejoin;
- socket close terminating every owned worker;
- ignoring stale results and stale senders before unsealing typed values.

The prototypes may be throwaway branches. They must not add a second shipped
runtime while the ADR remains proposed.

## Required correctness evidence

Run the existing Phoenix contract matrix against each viable prototype and add
focused tests for:

- a callback panic before and after join acceptance;
- a worker exit while an action batch is in flight;
- leave followed immediately by rejoin of the same topic;
- a stale typed sender targeting an earlier join generation;
- a socket disconnect while topic workers are busy;
- ordered replies, pushes, broadcasts, and presence operations;
- `JoinRef` and `ReplyRef` use after worker failure;
- runtime, session, and worker shutdown order;
- PubSub delivery during socket or channel teardown;
- connection-limit release after abnormal process exit;
- restart-intensity exhaustion in the enclosing beryl subtree.

No option is acceptable if it weakens capability identity, generation checks,
wire ordering, or transport ownership.

## Required performance evidence

Benchmark the current runtime and both prototypes with the same codec and
application callbacks. Measure:

- resident memory and process count;
- mailbox length under burst traffic;
- messages and reductions per client event;
- throughput;
- p50, p95, and p99 reply latency;
- broadcast fan-out latency;
- join and disconnect latency;
- time to contain a crashing or blocked callback.

Cover at least:

- many sockets with one topic each;
- fewer sockets with many topics each;
- mixed raw and channel-style workloads in separate socket systems;
- local broadcasts and cross-node PubSub;
- presence actions that suspend one ordered action list.

Set acceptance thresholds before comparing final benchmark results. The
decision must account for operational scale, not only single-connection
latency.

## Decision

beryl adopts option 2 for raw dispatch and option 3 for `beryl/channel`.

- **Raw dispatch: one process per socket.** Landed in
  [#343](https://github.com/tylerbutler/beryl/pull/343) (issue #334). The
  socket actor owns the raw model and runs `init` and `update`; the router
  stays a stable, named forwarder.
- **Channel layer: one process per socket and one process per joined topic.**
  [#371](https://github.com/tylerbutler/beryl/pull/371) implements issue #337.
  Each socket actor starts a linked factory supervisor and one `Temporary`
  worker for each accepted join. The worker owns the channel state and runs
  `join`, `on_message`, `on_info`, and `on_terminate`. The socket actor owns
  the protocol state, capabilities, subscriptions, presence data, and ordered
  send requests. The transport connection process performs frame writes.

beryl uses these sequence rules:

- Workers on one socket run message and info callbacks concurrently. A slow
  callback delays its worker, but joins, ordered closes, and presence
  suspension can also delay the socket actor's effect processing.
- beryl does not define an order between different topics on one socket.
  Within one topic, action order is wire order.
- The worker runs `join` during initialization. The socket actor waits for a
  maximum of 5 seconds. It rejects the join after this timeout. Joins on
  different sockets do not wait for each other.
- beryl does not limit worker mailboxes or pending reports.
  [#397](https://github.com/tylerbutler/beryl/issues/397) tracks these and other
  runtime queue contracts. [#249](https://github.com/tylerbutler/beryl/issues/249)
  separately tracks outbound connection queues and slow-client eviction.
- The socket actor owns presence suspension. Workers send presence actions to
  the socket actor. The socket actor applies the existing order rules.
- The socket actor sends a close to the worker before it drops the topic's
  reply refs. The actor waits until the worker runs `on_terminate`. The actor
  first applies results that the worker computed before the close. Thus, it
  can deliver a push or reply that the worker computed before a leave. The
  actor kills a worker that does not finish its queued work and
  `on_terminate` in 5 seconds. It drops replies that the worker still owes.

Contract changes recorded with this decision:

- An `on_info` panic closes only its topic. It previously tore down the
  socket.
- The runtime no longer has a special case for an `on_terminate` panic. It
  logs the panic, completes the close, and stops the worker. The sender for
  that worker cannot deliver more messages.
- If a worker process stops unexpectedly, the runtime closes its topic with
  `phx_error`. The runtime cannot run `on_terminate` because the worker held
  the channel state. The client must rejoin. This behavior matches Phoenix.

[#371](https://github.com/tylerbutler/beryl/pull/371) provides protocol-smoke
evidence, not comparative performance evidence for this topology. The
[ADR 0005 results](0005-socket-actor-supervision.md#results) compare direct
and factory startup at a requested 2,000 connections per second with Mist on
Erlang 27.2.1 and 12 schedulers, with three runs per design. That narrow
start-rate result does not establish general capacity, queue bounds, or
healthy-sibling latency under load.

[#400](https://github.com/tylerbutler/beryl/issues/400) tracks the broader
workload baselines. ADRs 0002 and 0003 remain authoritative for the raw and
channel APIs. This ADR changes their process topology;
[ADR 0005](0005-socket-actor-supervision.md) subsequently adds the shared
factory that owns socket actors as `Temporary` children. Neither socket nor
topic supervision reconstructs a session: clients reconnect and rejoin.

## Sources

- [Issue #228: shared-actor crash boundaries](https://github.com/tylerbutler/beryl/issues/228)
- [Issue #229: process-per-channel proposal](https://github.com/tylerbutler/beryl/issues/229)
- [Issue #334: evaluate one actor per socket](https://github.com/tylerbutler/beryl/issues/334)
- [Issue #337: process-per-channel prototype](https://github.com/tylerbutler/beryl/issues/337)
- [Erlang/OTP supervision principles](https://www.erlang.org/doc/system/sup_princ.html)
- [Erlang `supervisor` restart types](https://www.erlang.org/doc/apps/stdlib/supervisor.html)
- [Erlang `gen_event` callback-failure behavior](https://www.erlang.org/doc/apps/stdlib/gen_event.html)
- [Phoenix Channels architecture](https://hexdocs.pm/phoenix/channels.html)
- [Phoenix Channel callbacks and process lifecycle](https://hexdocs.pm/phoenix/Phoenix.Channel.html)
- [Gleam OTP factory supervisors](https://hexdocs.pm/gleam_otp/gleam/otp/factory_supervisor.html)
