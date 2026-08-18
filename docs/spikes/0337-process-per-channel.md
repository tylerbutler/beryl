# Spike: process-per-channel isolation (#337)

The prototype and its tests are not merged. They live on the branch
`feat/337-process-per-channel-spike` as
`packages/beryl/test/spike_channel_worker.gleam` and
`spike_channel_worker_test.gleam`; only these findings are merged here.

The prototype reuses `beryl/channel`'s own router seam: handlers, `join`,
state sealing, callbacks, actions, and action lowering are unchanged —
`channel.open` returns the same non-generic `LiveChannel` — and only which
process holds that value differs:

```text
shipped:  runtime actor ── LiveChannel per joined topic (in its model)
spike:    runtime actor ── worker(topic) ── LiveChannel
                        └─ worker(topic) ── LiveChannel
```

That is the whole difference, which is what makes the two comparable.
No `Dynamic`, no coercion, and no core change was needed to build it.

The seam it reuses (`channel.open`, `channel.effects`, `LiveChannel`,
`Step`, `RoutedJoinContext`, `JoinOutcome`) is `@internal`, so the spike
only compiles from inside the `beryl` package. **A transport package or a
user application could not build this shape at all** — which is a finding in
its own right, and sharpens the one below: this topology is not something a
layer can reach for from outside the core.

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
  worker on every socket is orphaned. The prototype pins that with
  `OneForAll`, so the factory restarts alongside the runtime; without it a
  restarted runtime leaves every worker holding a `Sender` for a dead
  process, with no `Finish` ever arriving to end them.
- It cannot start its workers off the hot path. `supervisor:start_child` is
  a `gen_server:call` handled synchronously in the factory supervisor, so
  **every join on every socket queues behind one process**, each for up to
  `join_timeout_ms`. Today the shared runtime already serialises joins, so
  this is not a regression — but it survives #334 unchanged, and would be
  the next thing to hit.

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
socket?** Per topic, order is preserved *between batches*: one worker
mailbox, FIFO, and the VM orders messages between one pair of processes. It
is **not** preserved between a batch and the topic's own close, which take
different paths home and race — see the third contract break below. Across
topics on one socket, nothing is preserved — two topics' replies can be interleaved in any
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

## Three contract breaks, all pinned by tests

1. **A crashed worker cannot run `on_terminate`.** Today core rescues the
   callback, keeps the model, and delivers `Closed`, so the channel's state
   is still there to terminate. Here the state died with the process. This
   matches Phoenix — a channel process crash skips `terminate/2` — but it is
   a change from what beryl documents today.
2. **A crashed channel closes as `phx_close`, not `phx_error`.** Core picks
   the frame from the stop reason, and the only way a layer can close a topic
   it no longer owns is `KickTopic`, which is `Shutdown`. Preserving this
   needs a core effect that carries a reason.

3. **A close discards the worker's in-flight batch.** A client that pushes
   and then leaves loses the push's reply entirely: the batch travels the
   slow path (worker → socket `Sender` → a later runtime turn) while the
   close is answered on a direct subject, so the router drops the topic
   before the batch gets home and then discards it. The client's `ref` is
   never answered. `a_leave_discards_the_reply_it_raced_test` pins it; the
   shipped shared runtime cannot lose this, because it runs `on_message` in
   the same process that handles the leave.

   **This one is not fixable from the router**, and that is the point. The
   router would have to drain its socket's outstanding envelopes before
   finishing, and it cannot: it is not a process, so it cannot selectively
   receive from the mailbox its own batches arrive in. A per-socket process
   (#334) can. This is the sharpest single piece of evidence that #337 is
   downstream of #334 rather than parallel to it.

A fourth difference is arguably an improvement: a panic in `on_info` closes
only its topic here, where today it tears down the whole socket.

There is also a cost that is not a contract break but is worse
operationally. A worker that dies before answering the router's synchronous
`Finish` would leave the `Closed` turn blocked — inside the one shared
runtime actor, so every socket with it — until `terminate_timeout_ms`
expired. That applies to a panicking `on_terminate` and, more commonly, to
any close that overtakes a crash the router has not yet learned about. The
prototype pays it down: `finish` selects on the worker's `DOWN` alongside
its reply, so a dead worker ends the wait at once, and
`a_dead_worker_does_not_stall_the_runtime_test` pins that.

What remains is an `on_terminate` that *blocks* rather than dies, which
still stalls every socket for up to `terminate_timeout_ms`. The shared
runtime has the same exposure to a blocking callback, so it is not new; what
a socket session (#334) adds is confinement of the stall to one connection.
A worker that blocks in `on_terminate` forever also leaks itself and its
watcher, since the router has already moved on — bounded in practice by the
same thing that bounds an infinite callback today, which is nothing.

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
socket session actually exists to own monitoring, backpressure, worker
lifetime, and the drain that the third contract break needs, and when the
watcher process — currently half the per-channel cost — disappears.

Things to carry forward into a real implementation, none of which the spike
resolves:

- The close/batch drain (third contract break). Needs the per-socket process.
- Join serialisation through the factory supervisor. Needs joins started off
  the calling process, or a supervisor per socket.
- A `Died` that arrives after a close, and a close that arrives after a
  `Died`, are both handled here by deleting the topic first and letting the
  other path miss. That works because a topic has exactly one ending; it
  will not survive a design where a worker can be replaced in place.
