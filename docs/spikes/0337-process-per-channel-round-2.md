# Spike: process-per-channel isolation (#337), round 2

Round 1 ([`0337-process-per-channel.md`](./0337-process-per-channel.md)) ran
on the shared runtime actor and concluded: *do not pursue process-per-channel
before [#334](./0334-per-socket-actor.md); reassess afterwards, when a socket
session exists to own monitoring, backpressure, worker lifetime, and the drain
the third contract break needs.*

#334's prototype has since landed on this branch. Round 2 re-ran the same
prototype on it and tried to claim each of those four things. Same files:
`packages/beryl/test/spike_channel_worker.gleam` and its test module, now 12
tests.

**Result: one of the four was real, one was free, and two were never blocked
on #334 at all.** The load-bearing one — the drain — turns out not to be a
topology problem in the first place.

## The finding that reframes round 1

**The raced reply is core's rule, not the topology's.** Round 1's third
contract break — a close discards the worker's in-flight batch, so a client
that pushes and then leaves never gets its reply — was blamed on the router
not being a process:

> It is not fixable from the router... The router would have to drain its
> socket's outstanding envelopes before finishing, and it cannot: it is not a
> process, so it cannot selectively receive from the mailbox its own batches
> arrive in. A per-socket process (#334) can. This is the sharpest single
> piece of evidence that #337 is downstream of #334.

That is wrong, and the evidence is
`a_reply_ref_is_dead_by_the_closed_turn_test`: **one plain `beryl.child_spec`
app, one socket, one process, no workers anywhere** — and the reply is still
lost. `exec_close_topic` (`runtime.gleam:2686`) deletes the topic's
`pending_reply_refs` *before* it delivers `Closed`, deliberately, so that
pushes to a closing topic drop while broadcasts still reach its remaining
subscribers. Any `ReplyOk` a layer returns from that turn names a ref core has
already invalidated.

### Why no drain rescues it

The drain round 1 asked for is, as it happens, *buildable* — and still
useless. Worth spelling out, because "we still cannot drain" and "draining
does not help" lead to different next steps.

It is buildable because `init` runs in the socket's own process, so a
`process.Subject` created there is owned by the socket actor, and a worker
sending its batches to that subject puts them in the socket actor's mailbox
under a tag the layer can name. `process.selector_receive(sel, 0)` on a
selector holding only that subject is an Erlang selective receive: it takes
the pending batches and leaves everything else in the mailbox. Ordering even
cooperates — `finish` calls the worker synchronously, the worker's mailbox is
FIFO, so any `Deliver` it was given is processed and reported *before* the
`Finish` reply comes back. By the time the layer would drain, the batch is
reliably there.

It is useless because the recovered effects are returned from the `Closed`
turn, and that is the one turn in which the topic's refs are already gone. The
drain hands the layer a `ReplyOk` for a ref core deleted a moment earlier.
(Not implemented: the outcome is decided by the ref invalidation, which the
no-workers test establishes on its own.)

### The ordering is lost where beryl's core owns the leave

Process-per-channel should *preserve* this ordering, not break it. In Phoenix
the channel process receives both the push and the `phx_leave` in its own
mailbox, in order, so the reply is produced before the leave is acted on —
ordering falls out of the topology for free. beryl's shipped runtime preserves
it for the same structural reason: one process handles `on_message` and the
leave.

The spike loses it because beryl's core, not the worker, receives the leave.
Core closes the topic and only then tells the layer, so the worker's reply is
already orphaned by the time anyone can act on it. The break is not "a channel
lives in its own process"; it is "a channel lives in its own process that the
leave never reaches". Nothing above `beryl.child_spec` can change who the
leave reaches.

This also makes the break a regression against beryl-today *and* against
Phoenix, rather than the Phoenix-parity trade contract breaks 1 and 2 are. It
is the one of the three that a real implementation should be expected to fix
rather than document.

## What #334 actually paid back

### Free: a blocking `on_terminate` now stalls one connection

Round 1's worst operational cost was a `Finish` that blocks — `finish` is a
synchronous call, and on the shared runtime the socket it blocked was every
socket. `a_blocking_terminate_stalls_only_its_own_socket_test` pins that it is
now confined, and it **passes against round 1's prototype unmodified**. The
`Finish` wait is unchanged; only the process it blocks is different.

### Claimed: a supervisor per socket, so joins stop serialising

Round 1 flagged this as the next thing to hit:

> every join on every socket queues behind one process... it survives #334
> unchanged.

It survives #334, but not #334 plus one change: each socket now starts its own
`factory_supervisor` in `init`, linked to its own socket actor.
`a_slow_join_does_not_block_another_socket_test` pins it — a 700ms join on
`s1` no longer delays `s2`'s join reply past a 500ms window. **Checked out
against round 1's worker module, that test fails**, so it discriminates the
topologies rather than merely passing.

The link is the other half. Round 1 needed a globally named factory wrapped
with the runtime in `OneForAll`, because a restarted runtime would otherwise
leave every worker on every socket holding a `Sender` for a dead process. A
socket-owned supervisor dies with its socket, so `child_spec` is now
`beryl.child_spec` and nothing else: the tree, the global name, and the
`OneForAll` coupling are all deleted.

## What round 1 over-booked

### The per-channel watcher was never a #334 cost

Round 1:

> The prototype pays for this with **one extra watcher process per channel**,
> so the real cost is two processes per join, not one... the first thing #334
> would pay back.

`init` has always run once per socket, and `info.self` has always been that
socket's own `Sender`. A single watcher holding one monitor per worker was
available on the shared runtime too — `start_watcher` is that, and nothing in
it depends on #334. Per-channel process cost is one worker, not two, and
always was. What #334 adds is only that the watcher is started by the socket's
own process and dies with it.

### There was always somewhere to put a per-socket budget

Round 1:

> It cannot hold a per-socket in-flight budget, because there is nowhere
> per-socket to hold one.

The `Router` record *is* per-socket, and was before #334 — `init` returns one
model per connection. A budget was always holdable. Not implemented here,
because implementing it would have produced no finding; what #334 changes is
what a budget would protect (one socket actor's own scheduler share) rather
than whether one can exist.

## What still has no owner

- **Backpressure.** Still not built. Worker mailboxes are unbounded.
- **An asynchronous join handshake.** Unchanged: core rejects a `Join` left
  unanswered when the update turn ends, so `join` still runs in the worker's
  initialiser with the socket actor blocked on it. The block is now confined
  to one socket, which makes it survivable but not free.
- **`on_terminate` after a crash**, and **`phx_error` vs `phx_close`** —
  contract breaks 1 and 2, both unchanged and both needing core changes (a
  rescued callback cannot exist across a dead process; `KickTopic` cannot
  carry a reason).

## Test status

`packages/beryl` runs 503 passed / 3 failures. The three failures are #334's
own contract breaks, unchanged and unrelated (see
[`0334-per-socket-actor-findings.md`](./0334-per-socket-actor-findings.md)):
the runtime-pid assertion in `channel_dispatch_test`, and two `stats_test`
cases that the statistics split is meant to resolve.

Still no benchmarks. That has not moved since round 1 and is still the only
thing that can decide whether any of this is worth shipping.

## Why a supervisor is still in the picture at all

The obvious simplification — drop the supervisor, have the socket actor
`actor.start` its own workers — does not work, and the reason constrains any
real implementation.

`actor.start` spawns **linked** to the caller
(`gleam_otp/src/gleam/otp/actor.gleam:592`), and gleam_otp actors do not trap
exits. A worker started that way would take its socket actor down when it
panicked, turning round 1's one genuine improvement — a panic in `on_message`
closes only its topic — into "a panic kills the connection". A supervisor is
the only construct that gives an unlinked child whose initialiser you can
still wait on synchronously, which the join handshake requires.

So the supervisor stays, and per-socket is the cheapest place to put it: the
socket actor is blocked on `start_child` for the duration of the join
callback either way, so confining the queue to one socket costs nothing that
was not already being paid. Linking that supervisor to the socket actor is
what supplies worker lifetime — socket actor dies, supervisor dies, workers
die — which is the piece of round 1's "socket session" that turned out to be
real.

## Recommendation

Round 1's "do not pursue before #334" is discharged. Of the four things it
wanted a socket session to own: worker lifetime and join serialisation were
real and are now claimed; the blocking-callback stall was real and #334
confines it for free; monitoring and the in-flight budget were never blocked
on #334 at all.

What replaces it is narrower and firmer: **process-per-channel cannot be built
on top of `beryl.child_spec`, and should not be attempted there.** Round 1
showed the seam it needs is `@internal`, so no transport or application can
reach it. Round 2 shows that even with the seam opened, the ordering the
design depends on is decided by who receives the leave — and that is core.

### What a real implementation looks like

Not a layer. A change to `beryl/runtime.gleam` in which the socket actor owns
its channels directly:

- The socket actor holds `Dict(topic, worker)` and monitors its workers on its
  **own** selector. No watcher process at all — that cost disappears here, one
  round later than round 1 expected and for a different reason.
- A leave is routed *to the worker* and the topic closes on the worker's
  outcome, rather than closing first and notifying after. This is the whole
  fix for the raced reply, and it is only expressible from inside core.
- Its supervisor is per-socket and linked, as prototyped here.
- `join` still runs in the worker's initialiser until core grows a join that
  can stay pending across turns. Confined to one socket, that is survivable.

### What to settle before writing it

1. **Benchmark.** Unchanged from round 1 and from #334's plan, and still the
   only thing that can decide whether any of this ships. One process per
   channel plus one extra message hop per reply, against callbacks running on
   more than one scheduler. Whether that trades depends on callback cost,
   which nobody has measured. A cheap callback makes this pure overhead; an
   expensive one makes it the whole point.
2. **Decide the close ordering as a documented semantic**, not as an
   implementation detail: does a leave wait for the channel's in-flight work?
   Round 1 read the answer as a bug to be drained away; it is a contract. Both
   beryl-today and Phoenix answer yes, which is a strong argument for keeping
   it — but keeping it is what forces the worker into core, so the cost of the
   answer should be accepted deliberately.
3. **Decide contract breaks 1 and 2** — `on_terminate` lost to a crash, and
   `phx_close` where beryl documents `phx_error`. Both are unchanged by #334
   and both are Phoenix-parity trades rather than regressions, so they are
   candidates for documenting rather than fixing. Fixing break 2 needs a core
   effect that carries a stop reason; break 1 cannot be fixed at all while the
   channel's state lives in the process that died.

## What round 2 did not do

No benchmarks, no cross-node or presence-heavy workloads, no binary frame
path, and the Phoenix contract matrix was still not run against the spike. The
drain was argued rather than built, for the reason given above. Backpressure
is still absent.
