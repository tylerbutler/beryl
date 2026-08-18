# Spike plan: one actor per socket (#334)

A plan, not a spike. Nothing has been prototyped or measured. Read against
`main` at `d2acc2b`; every file and line reference below is that tree.

**Update:** the prototype this plan describes has since been built on
`feat/334-per-socket-actor-spike`. See
[`0334-per-socket-actor-findings.md`](./0334-per-socket-actor-findings.md)
for what it found. Still unmeasured — step 0 below remains blocking.

[#337](https://github.com/tylerbutler/beryl/issues/337) was spiked first and
concluded it is downstream of this issue — see
[`0337-process-per-channel.md`](./0337-process-per-channel.md). Two of the
three contract breaks it found trace back to the same root cause: a socket is
not a process, so nothing can own per-socket monitoring, backpressure, or a
drain. This issue is where that gets fixed, and the plan below is shaped by
what #337 learned the expensive way.

## The seam already exists

`handle_message` (`runtime.gleam:517`) already partitions the runtime's own
mailbox into exactly the two halves this issue asks for. Six variants are
socket-scoped and dispatch through `dispatch_socket_msg`
(`runtime.gleam:601`); the rest — `AdmitSocket`, `Broadcast`,
`RemoteBroadcast`, `CheckHeartbeats`, `GetStats`, `Stop` — are router-scoped
and never reach it. That function *is* the socket actor's `handle_message`,
already written and already tested.

The state splits along the same line. Every one of

```text
sockets  message_buckets  join_buckets  channel_buckets
suspended  queued  unacked_tracks
```

is a `Dict(socket_id, _)`, and becomes a plain field on the socket actor.
What is genuinely router-owned is `topics`, `pubsub`, `subscriber`, `config`,
and `logger`.

`Sender` is an opaque closure (`socket.gleam:263`) built at
`runtime.gleam:801` as a send of `AppInfo(socket_id, message)` to the runtime
subject. It captures the socket actor's subject instead. No signature
changes, and it stops routing every server-side message through the router.

So the rewrite is mostly a move, not a redesign. The design work is in the
six decisions below, all of which are about what the router keeps.

## Step 0: benchmarks, before any code

The issue asks for thresholds set before final numbers. None are set, there
is no bench harness in the repository, and #337 could not answer its own
cost question without one. Both issues reduce to a single number:

**Is app callback cost large enough to pay for a message hop?**

Below some callback cost the shared actor wins and both issues close as
"won't do". Above it, this issue is worth its complexity and #337 becomes
worth reassessing.

Build the harness against today's runtime, on `main`, before touching the
topology. Workloads the issue names: connection churn, push round-trip,
broadcast fan-out, presence. Report throughput, p95/p99, scheduler
utilisation, mailbox depth, memory, process count. Sweep a synthetic
callback cost across at least three orders of magnitude and find the
crossover. That crossover is the decision.

## Six decisions

### 1. How a broadcast reaches a socket

`local_broadcast` (`runtime.gleam:3730`) encodes the frame and calls each
socket's `send` closure **from the router**, inside the router's turn. Keep
that under per-socket actors and two processes write to one transport
concurrently, so a broadcast can overtake a frame the socket actor has
already decided to send. That is #337's third contract break in a new
costume, and it would be just as unfixable from the router.

The alternative is to route broadcasts through the socket actor: one extra
hop per recipient, but per-socket encoding moves off the router onto N
schedulers, which should pay for itself at fan-out.

Recommend the hop. Measure it — this is the single largest performance
question in the rewrite, because broadcast fan-out is the workload where the
shared actor is currently at its best.

### 2. Who owns the topic index

Today `topics` is updated in the same turn as the join that caused it, which
is why a broadcast issued immediately after a join can never miss that
socket. Under per-socket actors the join happens somewhere else, and every
option costs something:

- **Router keeps the index, updated by synchronous call.** Every join on
  every socket serialises through the router. This is precisely what the
  #337 factory supervisor did, and it was the finding that survived that
  spike unchanged.
- **Router keeps the index, updated by cast.** Joins stay parallel, but a
  window opens where the index lags the socket's real join state and a
  broadcast misses a just-joined socket. New observable behaviour.
- **Socket actors join `pg` groups directly.** `pubsub.gleam` already
  supports per-process subscription — `subscriber` (`:194`), `join`
  (`:202`), `leave` (`:207`), `subscribers` (`:304`),
  `subscriber_count` (`:309`). The router would hold no topic index at all,
  and remote broadcasts would reach socket actors with no router hop
  whatsoever.

The third is the most attractive and has the sharpest catch: `pubsub` is
`Option` on the runtime config, so this means always starting a local `pg`
scope, including for single-node deployments that configure no PubSub. That
is a real cost to weigh, not a free reuse.

### 3. Presence suspension is the deletion opportunity

The `Step` / `Cont` / `Suspension` machinery — the interpreter at
`runtime.gleam:1858`, its `Await` parking, `suspended`, and `queued` —
exists for exactly one reason: one actor cannot block on the presence actor
without stalling every socket. A per-socket actor can. A `process.try_call`
bounded by `presence_op_timeout_ms` stalls only its own socket, which is
already the behaviour suspension goes to great lengths to produce.

If that holds, most of the step reification deletes. It should be validated
against `app_presence_async_test` and `effect_ordering_test` before it is
assumed, because the step machine also carries close-cleanup ordering, not
just presence parking.

One documented behaviour tightens rather than breaks. Today's architecture
page says "an unrelated broadcast can land between two of the waiting
socket's effects"
(`website/src/content/docs/architecture/runtime.md:48`). Under a blocking
call the broadcast queues in the socket actor's mailbox and lands after the
effect list instead. That is a strictly stronger guarantee, so it is a
documentation edit, not a contract break — but it is a behaviour change and
belongs in the changelog.

### 4. Admission must not become the new bottleneck

`AdmitSocket` is a synchronous router call and has to stay atomic: the
connection limit and the admission token are claimed together. But starting
the socket actor *inside* that turn makes `supervisor:start_child` a
serialised synchronous call per connection, which is #337's join
serialisation transposed onto connections, and it would cap connection
setup rate at one process.

Prefer having the transport's connection process start the socket actor,
then hand it to the router for an O(1) atomic admit. Startup stays parallel
and the router turn stays short. This needs care around a socket actor that
starts and is then refused admission — it must be stopped, and the
admission token cancelled, without leaking either.

### 5. Router failure semantics

Transports monitor the router pid through `transport.runtime_pid`
(`transport.gleam:243`), and the issue requires that router failure keeps
its current connection-close and supervised-restart behaviour. So the router
stays the named, stable owner, and its death has to take every socket actor
with it — `one_for_all`, or `rest_for_one` with the router started first.

#337 hit the orphan case directly: without `OneForAll`, a restarted runtime
left every worker holding a `Sender` for a dead process with no termination
message ever arriving. The same failure is available here at socket scale.

### 6. Crash containment does not change

Resist converting the `internal.rescue` boundaries to let-it-crash. Today a
crashing topic-scoped `Message` closes only that topic; letting the socket
actor die instead widens that to the whole socket, which the issue's own
investigation criteria forbid. The *rationale* in the architecture page
changes — per-socket state is no longer shared, so the original argument for
rescuing weakens — but the behaviour must be preserved as-is and pinned by
`app_crash_test` and `channel_crash_test` unchanged.

## Phasing

1. **Bench harness and thresholds** on today's runtime. Blocking; nothing
   below is decidable without it.
2. **Split the statistics API.** `stats.runtime_mailbox_length`
   (`stats.gleam:69`) assumes one runtime mailbox and is a pre-1.0 leak the
   issue already calls out. It is shippable on `main` independently of any
   topology change, and it should ship first so the rewrite is not also an
   API break.
3. **Move heartbeat ownership to per-socket timers.** Deletes the O(N)
   router sweep (`runtime.gleam:948`) and its awkward interaction with
   suspended sockets. A strict improvement whether or not the rest of this
   ever lands.
4. **Prototype the socket actor** by lifting `dispatch_socket_msg` as-is,
   wiring decisions 1 and 2 the cheap way first so the expensive options are
   compared against something that works.
5. **Run the whole suite unchanged.** 72 test files in
   `packages/beryl/test`, plus `channel_wire_matrix` and the
   `phoenix_channel_fixtures` matrix. Any test that needs editing to pass is
   a contract break, and it gets written down here rather than edited away.
6. **Benchmark against step 1's thresholds**, then decide.

## What this adds and what it removes

Removed: three per-socket rate-limit dicts, `suspended`, `queued`, the
router heartbeat sweep, probably most of the step interpreter, and the
router hop on every `Sender` send.

Added: one supervisor, one hop per broadcast recipient, one hop per
join/leave index update (unless decision 2 goes to `pg`), and the socket
actor's own scaffolding.

Net line count plausibly goes down. That is an argument for doing this even
if the throughput case comes back weaker than hoped — but it is a guess
until step 4 exists, and it should not be used to pre-empt step 1.

## What this plan does not answer

- **Whether it is worth doing.** That is step 1's job, and no number in this
  document is measured.
- **Cross-node behaviour.** If decision 2 goes to `pg`, remote broadcast
  delivery changes shape and `presence_replication_test` becomes the
  interesting suite. Not analysed here.
- **The `except` / `from_socket` filtering path** under per-socket
  subscription. `broadcast_from_socket` (`pubsub.gleam:270`) currently
  filters at a single point in the router; where that filtering lands when
  subscribers are separate processes is unresolved.
- **Backpressure.** The issue does not ask for it and this plan does not add
  it, but a per-socket process is the first place beryl could hold an
  in-flight budget — which is what #337 found it was missing. Worth
  designing for, not worth building yet.
