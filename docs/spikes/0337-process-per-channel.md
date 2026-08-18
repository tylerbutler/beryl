# Spike: process-per-channel isolation (#337)

Prototype: `packages/beryl/test/spike_channel_worker.gleam`.
Pinned behaviour: `packages/beryl/test/spike_channel_worker_test.gleam`.

The prototype is built entirely on beryl's public core API, the way
`beryl/channel` is. It reuses that layer's handlers, `join`, state sealing,
callbacks, actions, and action lowering unchanged — `channel.open` returns
the same non-generic `LiveChannel` — and changes only which process holds
that value:

```text
shipped:  runtime actor ── LiveChannel per joined topic (in its model)
spike:    runtime actor ── worker(topic) ── LiveChannel
                        └─ worker(topic) ── LiveChannel
```

That is the whole difference, which is what makes the two comparable.
No `Dynamic`, no coercion, and no core change was needed to build it.

## The finding that reframes the issue

**A socket is not a process, so the "socket session" in the issue's
candidate shape does not exist and cannot be built from outside the core.**
Everything the session was supposed to do lands on the router, which runs
inside the one shared runtime actor:

- It cannot monitor its workers. `DOWN` goes to the process that called
  `monitor`, and the router does not own the runtime actor's selector. The
  prototype pays for this with **one extra watcher process per channel**,
  so the real cost is two processes per join, not one.
- It cannot hold a per-socket in-flight budget, because there is nowhere
  per-socket to hold one.
- It cannot link workers to the connection. If the runtime actor dies, every
  worker on every socket is orphaned until the factory supervisor goes down
  with it.

So #337 is downstream of [#334](https://github.com/tylerbutler/beryl/issues/334),
not parallel to it. Process-per-channel on top of process-per-socket is a
coherent design; process-per-channel on today's shared runtime buys callback
concurrency and pays for it with a watcher process per channel and the two
contract breaks below.

## Answers to the questions the issue asked

**Does the socket permit one in-flight callback, or can workers run
concurrently?** Concurrently after join, serially during it. `join` and
`on_terminate` are synchronous calls from the router; everything else is a
cast, so N joined topics on one socket can be executing callbacks at once.

**What ordering remains between actions from different topics on one
socket?** Per topic, total order is preserved: one worker mailbox, FIFO, and
the VM orders messages between one pair of processes. Across topics on one
socket, nothing is preserved — two topics' replies can be interleaved in any
order regardless of the order the client sent them. **This is a change from
today**, where the shared runtime serialises the whole socket. Phoenix does
not promise cross-topic ordering either, so the question is whether beryl
wants to keep promising more than Phoenix does.

**Does `join` execute during child startup or through an asynchronous
handshake?** During child startup — an asynchronous handshake is not
representable. Core rejects a `Join` that is unanswered when the update turn
ends (fail-closed), so the router has to have the outcome before it returns.
The prototype therefore runs `join` in the worker's initialiser and blocks
the runtime on `factory_supervisor.start_child`. An async handshake needs a
new core capability: a join that can be left pending across turns.

**How are join timeout, worker startup failure, and worker death during an
action batch represented?** All three are distinguishable. A join that overruns the initialiser timeout
rejects with `join timeout` — a reason core has no equivalent for, because
core cannot time a callback out at all, so it is a wire value this topology
adds. A panicking join rejects with core's own `join crashed`. Worker death
is a `Died` envelope from the watcher, which drops the topic from the router
and kicks it; a batch in flight from that worker is then discarded by the
generation check, since the topic is no longer live.

**How does the session apply backpressure to worker mailboxes and pending
action batches?** It does not. Worker mailboxes are unbounded and batches
are applied as fast as they arrive. A budget needs a per-socket owner (#334).

**Which process owns presence suspension while an asynchronous presence
mutation is in flight?** Unchanged — the runtime. Workers emit actions;
`PresenceTrack`/`PresenceUntrack` are core effects applied by the runtime,
which is also what makes it necessary for the router, not the worker, to
apply every batch.

**How does socket shutdown terminate workers and preserve `on_terminate`?**
Core delivers `Closed` for every joined topic on teardown, and the router
answers each one with a synchronous `Finish` call before the turn ends —
`on_terminate`'s actions have to be lowered inside that turn. Workers stop
on the way out, and `a_disconnect_terminates_every_worker_test` pins that no
worker outlives its socket.

## Two contract breaks, both pinned by tests

1. **A crashed worker cannot run `on_terminate`.** Today core rescues the
   callback, keeps the model, and delivers `Closed`, so the channel's state
   is still there to terminate. Here the state died with the process. This
   matches Phoenix — a channel process crash skips `terminate/2` — but it is
   a change from what beryl documents today.
2. **A crashed channel closes as `phx_close`, not `phx_error`.** Core picks
   the frame from the stop reason, and the only way a layer can close a topic
   it no longer owns is `KickTopic`, which is `Shutdown`. Preserving this
   needs a core effect that carries a reason.

A third difference is arguably an improvement: a panic in `on_info` closes
only its topic here, where today it tears down the whole socket.

There is also a cost that is not a contract break but is worse
operationally, and the prototype does not currently pay it down: **a panic
inside `on_terminate` freezes every socket for a full second.** The worker
dies before it can answer the router's synchronous `Finish`, so the `Closed`
turn blocks in `process.receive` — inside the one shared runtime actor —
until `terminate_timeout_ms` expires. Nothing else on that runtime moves in
the meantime. It is fixable within this topology by selecting on the
worker's `DOWN` alongside its reply, so a dead worker ends the wait at once;
it is worth stating plainly because the shared runtime has no equivalent
failure mode, and because a socket session (#334) would confine the stall to
one connection instead of all of them.

## What was not done

- **No benchmarks.** The issue asks for thresholds to be set before final
  numbers, and none are set. What can be said without measuring: two
  processes per joined channel (worker plus watcher) against zero today,
  plus one extra message hop for every reply, against the ability to run
  callbacks on more than one scheduler. Whether that trade pays depends
  entirely on callback cost, which is the thing to measure first.
- **No cross-node, presence, or broadcast workloads**, and no binary frame
  path — the binary path is `Deliver`'s shape exactly.
- **The Phoenix contract matrix was not run against the spike.** It is wired
  to `beryl.child_spec` and `channel.child_spec`; the two breaks above say
  what it would report.

## Recommendation

Do not pursue process-per-channel before #334. Reassess afterwards, when a
socket session actually exists to own monitoring, backpressure, and worker
lifetime, and when the watcher process — currently half the per-channel cost
— disappears.
