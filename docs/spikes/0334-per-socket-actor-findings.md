# Spike: one actor per socket (#334) — prototype findings

The prototype lives on the branch `feat/334-per-socket-actor-spike` as a
single change to `packages/beryl/src/beryl/runtime.gleam` (+470/−63). It is a
prototype: it wires each of the plan's six decisions the cheap way, and the
shortcuts it takes are marked with `ponytail:` comments naming their ceiling
and upgrade path. It has not been benchmarked, which is
[the plan](./0334-per-socket-actor.md)'s step 1 and still the only thing that
can decide whether any of this is worth shipping.

## The lift was the whole trick

The plan said the rewrite is "mostly a move, not a redesign". It is less than
that: **the socket actor runs the same `handle_message` on the same `State`
type as the router.** A socket actor is the runtime with `sockets` capped at
one entry, `topics` holding only that socket's own memberships, no PubSub
subscriber, and one new field set:

```gleam
router: Option(Subject(Msg(msg)))   // None in the router, Some(router) in a socket actor
```

Nothing in the ~3,000 lines of socket-scoped logic below `dispatch_socket_msg`
was touched. `Sender` (`make_socket_sender`) captures `state.self_subject`, so
it became the socket actor's subject with no edit at all. Every branch that
had to change branches on that one field, in six places:

| Function | Router | Socket actor |
|---|---|---|
| `handle_message` (socket-scoped variants) | forward to the socket's actor | dispatch as before |
| `handle_admit_socket` | check owner, start the actor, hand it the registration | register |
| `add_topic_subscriber` / `remove_topic_subscriber` | own the index and the pg subscription | keep its own copy, cast the change to the router |
| `local_broadcast` | resolve recipients, one `Broadcast` per socket actor | encode and send for its own socket |
| `broadcast_with_pubsub` | fan out locally, forward to PubSub | deliver inline to itself, then hand the rest to the router |
| `Stop` | drain socket actors in two phases | tear down |

`packages/beryl_mist` and `packages/beryl_ewe` were not touched and both
suites pass unchanged (29 and 21 tests). The transport SPI never sees the
topology, because `beryl.app_dispatch` was already a record of closures.

## The whole suite runs: 487 passed, 3 failed

All 60 test modules in `packages/beryl/test`, including `channel_wire_matrix`,
`phoenix_binary_test`, `presence_replication_test`, and `pubsub_test`. No test
was edited. The three failures are the contract breaks, and all three are ones
the issue is asking for rather than accidents:

1. **`channel_dispatch_test:join_and_info_run_in_the_same_runtime_process_test`**
   — `join_pid == info_pid` still holds; both run in the socket actor. What
   fails is the last line, `join_pid |> should.equal(runtime)`. App callbacks
   no longer run in the runtime pid. That is #334's entire point, and this is
   the only test that pins it.
2. **`stats_test:snapshot_times_out_while_runtime_is_busy_test`** — expects
   `Error(RequestTimedOut)` while an app callback is blocking; it now gets
   `Ok(Snapshot(1, 1, 1, 0))`, because the router is not the process running
   that callback. This is the plan's phasing step 2 (`stats.runtime_mailbox_length`)
   arriving as a test failure.
3. **`stats_test:snapshot_tracks_socket_lifecycle_test`** — reads
   `connected_sockets` as 2 where 1 is expected. A disconnect is now
   asynchronous: the socket actor tears itself down and the router learns from
   a `SocketClosed` message that has not necessarily arrived when the snapshot
   is taken. Stats are eventually consistent under this topology.

Failures 2 and 3 are the same finding wearing two hats: **the statistics API
has to be split before this topology can ship**, exactly as phasing step 2
predicted, and it is the one piece that is shippable on `main` today.

## Two orderings the plan did not name, both fixable

Both were found by tests, and both cost real code to preserve. Neither is
visible in the plan.

### Effect-list order stops being wire order at the first broadcast

Routing broadcasts through the router (decision 1) means a socket's *own* copy
of a broadcast it originated takes a round trip, while the frames that follow
it in the same effect list go out immediately. A `Broadcast` effect followed
by a `Push` arrives in the wrong order. Five `app_presence_async_test` tests
caught this.

The fix is cheap and exact: the socket actor delivers to itself inline, then
asks the router to fan out with itself excluded. It is exact because the only
`except` a socket actor ever originates is its own id (`BroadcastFrom`), so
one exclusion always suffices. Worth stating plainly in the plan, because a
naive reading of decision 1 produces this bug.

### Shutdown has to be two-phase

`handle_stop` finalized every socket's in-flight presence mutation *before* it
tore any socket down, so a socket's shutdown leaves reached the sockets still
watching that topic. Told to stop concurrently, socket actors race: a watcher
can be gone before the leave is fanned out to it. Two tests caught this
(`shutdown_while_untrack_pending_…`, `shutdown_while_replacement_pending_…`).

The prototype splits the old `handle_stop` at exactly the seam that already
existed: `FinalizeForStop` to everyone, wait for all of them, then
`StopSocketActor` to everyone, then wait for the last `SocketClosed`. The
router must stay responsive throughout — a blocking `process.call` per socket
actor deadlocks against the socket actors' own index updates and drops their
teardown broadcasts. That is worth writing into the plan as a constraint: **the
router can never make a blocking call into a socket actor.**

## How each decision was wired, and what it cost

- **1 (broadcast reaches a socket)** — the hop, as recommended, plus inline
  self-delivery. Fan-out is now: router resolves the subscriber set, sends one
  `Broadcast` per recipient, and each actor encodes its own frame. Broadcast
  `send_failures` telemetry is dead in this topology — the router cannot see
  the sends. Unmeasured; this is the number step 1 exists to produce.
- **2 (topic index)** — the router keeps it, updated by cast. Not because cast
  is better than call, but because a call cannot be made safely (see above).
  The cast is sent from `subscribe_socket`, before the join reply leaves the
  turn, so a client that acts on its own reply cannot beat its index entry to
  the router. A broadcast originated by a *third* process can still race it;
  no test caught that, and the window is real.
- **3 (presence suspension)** — **not attempted.** `Step`/`Cont`/`Suspension`
  is intact and all 22 `app_presence_async_test` tests pass with it. The
  deletion opportunity is unevaluated, and the shutdown finding above suggests
  the step machine's close-cleanup ordering is doing more load-bearing work
  than the presence parking alone.
- **4 (admission)** — the router starts the socket actor inside the admission
  turn and waits for it to register. Serialised, exactly the bottleneck the
  plan warned about; the transport-side start is the upgrade and was not built.
- **5 (router failure)** — a monitor, not a supervisor. Socket actors are
  unlinked from the router (so a socket crash cannot kill it) and stop on the
  router's `Down`. This is a stand-in for `one_for_all`, not a substitute.
- **6 (crash containment)** — unchanged. `internal.rescue` boundaries were not
  touched and `app_crash_test` and `channel_crash_test` pass unedited.

## What this is not

- **Benchmarked.** No harness was built. Everything above is a correctness
  result. The plan's step 1 is still blocking and still the decision.
- **Nothing was deleted.** The plan predicted net line count might go down;
  it went up by 407, because the prototype adds the split without taking any
  of the removals (suspension, the router heartbeat sweep is gone, but the
  three rate-limit dicts, `suspended`, `queued`, and the step interpreter all
  remain). The deletion case is still a guess.
- **Cross-node behaviour is untested beyond the existing suite.**
  `presence_replication_test` and `pubsub_test` pass, but the router is still
  the only pg member; decision 2's "socket actors join pg directly" option was
  not built.
- **Backpressure.** Not added, as the plan says.

## Recommendation

The topology works and the seam is real: one field, six branches, no change to
the socket-scoped logic, no change to either transport. That is a much cheaper
rewrite than the plan assumed, which strengthens the case for doing it.

Ship phasing step 2 (the statistics split) on `main` now — two of the three
failures are it, it is independent of the topology, and it is an API break
that should not be bundled with one.

Then build the benchmark harness. Nothing else here should be decided without
it.
