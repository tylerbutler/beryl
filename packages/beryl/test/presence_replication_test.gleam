import beryl/presence
import beryl/pubsub
import gleam/erlang/process
import gleam/json
import gleam/list
import gleeunit
import gleeunit/should
import lattice_presence/presence_state
import test_helpers

pub fn main() {
  gleeunit.main()
}

// ── Helper ──────────────────────────────────────────────────────────

/// Create a unique PubSub scope per test to avoid cross-test interference
fn test_pubsub(name: String) -> pubsub.PubSub(presence.SyncPayload) {
  let config = pubsub.config_with_scope("test_presence_repl_" <> name)
  pubsub.start(config)
}

fn test_config(
  ps: pubsub.PubSub(presence.SyncPayload),
  replica: String,
  interval_ms: Int,
) -> presence.Config {
  presence.default_config(replica)
  |> presence.with_pubsub(ps)
  |> presence.with_broadcast_interval(interval_ms)
}

// ── BroadcastTick sends state via PubSub ────────────────────────────

pub fn broadcast_tick_sends_state_test() {
  let ps = test_pubsub("bcast_tick")

  // Start presence with a short broadcast interval
  let config = test_config(ps, "node1", 50)
  let assert Ok(p) = presence.start(config)

  // Track an entry
  let _ =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.string("meta"))

  // Subscribe to the sync topic to observe broadcasts
  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, "beryl:presence:sync")

  // Poll until a PubSub message arrives from the broadcast tick
  let selector =
    process.new_selector()
    |> pubsub.selecting(sub, fn(_msg) { True })

  test_helpers.wait_until(
    fn() {
      case process.selector_receive(from: selector, within: 0) {
        Ok(_) -> True
        Error(_) -> False
      }
    },
    2000,
    20,
  )

  // Clean up: leave to avoid polluting other tests
  pubsub.leave(sub, "beryl:presence:sync")

  // Drain any remaining messages from the mailbox
  drain_mailbox()
}

// ── Two presence actors converge via PubSub ─────────────────────────

pub fn two_replicas_converge_via_pubsub_test() {
  let ps = test_pubsub("converge_2")

  let config1 = test_config(ps, "node1", 50)
  let config2 = test_config(ps, "node2", 50)

  let assert Ok(p1) = presence.start(config1)
  let assert Ok(p2) = presence.start(config2)

  let _ = presence.track(p1, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p2, "room:lobby", "user:2", "socket-2", json.null())

  // Wait for broadcast ticks to fire and replicate
  test_helpers.wait_until(
    fn() { list.length(presence.list(p1, "room:lobby")) == 2 },
    2000,
    20,
  )
  test_helpers.wait_until(
    fn() { list.length(presence.list(p2, "room:lobby")) == 2 },
    2000,
    20,
  )

  let entries1 = presence.list(p1, "room:lobby")
  let entries2 = presence.list(p2, "room:lobby")

  list.length(entries1) |> should.equal(2)
  list.length(entries2) |> should.equal(2)
}

// ── Self-broadcasts are ignored ─────────────────────────────────────

pub fn self_broadcast_ignored_test() {
  let ps = test_pubsub("self_bcast")

  let config = test_config(ps, "node1", 50)
  let assert Ok(p) = presence.start(config)

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  // Wait for several broadcast ticks to ensure self-broadcast doesn't duplicate.
  // This is a negative test (verifying something does NOT happen), so a sleep
  // is the correct approach -- there's no condition to poll for.
  process.sleep(200)

  // Should still only have 1 entry (self-broadcast doesn't duplicate)
  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(1)
}

// ── Receiving remote state triggers merge ───────────────────────────

pub fn remote_state_triggers_merge_via_pubsub_test() {
  let ps = test_pubsub("remote_merge")

  // Node1 with broadcasting disabled (manual control)
  let config1 =
    presence.default_config("node1")
    |> presence.with_pubsub(ps)
    |> presence.with_broadcast_interval(0)
  let assert Ok(p1) = presence.start(config1)

  // Node2 with broadcasting enabled
  let config2 = test_config(ps, "node2", 50)
  let assert Ok(p2) = presence.start(config2)

  // Track on node2
  let _ = presence.track(p2, "room:lobby", "user:2", "socket-2", json.null())

  // Wait for node2's broadcast to reach node1
  test_helpers.wait_until(
    fn() { list.length(presence.list(p1, "room:lobby")) == 1 },
    2000,
    20,
  )

  // Node1 should now see node2's entry via PubSub replication
  let entries = presence.list(p1, "room:lobby")
  list.length(entries) |> should.equal(1)

  let assert [entry] = entries
  entry.key |> should.equal("user:2")
}

pub fn remote_merge_updates_read_model_count_test() {
  let ps = test_pubsub("remote_merge_count")

  let config1 =
    presence.default_config("node1")
    |> presence.with_pubsub(ps)
    |> presence.with_broadcast_interval(0)
  let assert Ok(p1) = presence.start(config1)

  let config2 = test_config(ps, "node2", 50)
  let assert Ok(p2) = presence.start(config2)

  presence.count(p1, "room:lobby") |> should.equal(0)

  let _ = presence.track(p2, "room:lobby", "user:2", "socket-2", json.null())

  // `count` is served from the read model too -- confirm the merge
  // republishes it, not just `list`.
  test_helpers.wait_until(
    fn() { presence.count(p1, "room:lobby") == 1 },
    2000,
    20,
  )
  presence.count(p1, "room:lobby") |> should.equal(1)
}

// ── Multi-replica convergence ───────────────────────────────────────

pub fn three_replicas_converge_test() {
  let ps = test_pubsub("converge_3")

  let config1 = test_config(ps, "node1", 50)
  let config2 = test_config(ps, "node2", 50)
  let config3 = test_config(ps, "node3", 50)

  let assert Ok(p1) = presence.start(config1)
  let assert Ok(p2) = presence.start(config2)
  let assert Ok(p3) = presence.start(config3)

  let _ = presence.track(p1, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p2, "room:lobby", "user:2", "socket-2", json.null())
  let _ = presence.track(p3, "room:lobby", "user:3", "socket-3", json.null())

  // Wait for convergence (all replicas see all 3 entries)
  test_helpers.wait_until(
    fn() { list.length(presence.list(p1, "room:lobby")) == 3 },
    2000,
    20,
  )
  test_helpers.wait_until(
    fn() { list.length(presence.list(p2, "room:lobby")) == 3 },
    2000,
    20,
  )
  test_helpers.wait_until(
    fn() { list.length(presence.list(p3, "room:lobby")) == 3 },
    2000,
    20,
  )

  let entries1 = presence.list(p1, "room:lobby")
  let entries2 = presence.list(p2, "room:lobby")
  let entries3 = presence.list(p3, "room:lobby")

  list.length(entries1) |> should.equal(3)
  list.length(entries2) |> should.equal(3)
  list.length(entries3) |> should.equal(3)
}

// ── Start without PubSub still works ────────────────────────────────

pub fn presence_without_pubsub_still_works_test() {
  let config = presence.default_config("standalone")
  let assert Ok(p) = presence.start(config)

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(1)
}

// ── Untrack propagation via PubSub ───────────────────────────────────

pub fn untrack_propagates_via_pubsub_test() {
  let ps = test_pubsub("untrack_prop")

  let config1 = test_config(ps, "node1", 50)
  let config2 = test_config(ps, "node2", 50)

  let assert Ok(p1) = presence.start(config1)
  let assert Ok(p2) = presence.start(config2)

  // Track on node1
  let ref = presence.track(p1, "room:lobby", "user:1", "socket-1", json.null())

  // Wait for convergence -- both should see the entry
  test_helpers.wait_until(
    fn() { list.length(presence.list(p2, "room:lobby")) == 1 },
    2000,
    20,
  )

  // Untrack on node1
  presence.untrack(p1, ref)

  // Wait for the untrack to propagate via next broadcast tick
  test_helpers.wait_until(
    fn() { presence.list(p2, "room:lobby") == [] },
    2000,
    20,
  )

  // Node2 should see the removal
  list.length(presence.list(p2, "room:lobby")) |> should.equal(0)
}

// ── Resilience: malformed sync messages ──────────────────────────────
//
// The sync payload is now a native, typed `SyncPayload` term rather than a
// JSON string, so the previous "malformed JSON string" and "wrong schema"
// scenarios can no longer be constructed through the public API at all —
// the compiler rejects them. The one still-reachable failure mode is an
// envelope whose version this node does not recognise (e.g. a peer running
// a newer/older presence build), which `handle_sync_payload` discards
// rather than attempting to interpret.

pub fn survives_unknown_envelope_version_test() {
  let ps = test_pubsub("malform_version")
  let config =
    presence.default_config("node1")
    |> presence.with_pubsub(ps)
  let assert Ok(p) = presence.start(config)

  // Track an entry to prove the actor is alive
  let _ = presence.track(p, "room:lobby", "user:1", "s1", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)

  // Send a sync envelope with a version this node does not understand
  pubsub.broadcast(
    ps,
    "beryl:presence:sync",
    "presence_sync",
    presence.SyncPayload(
      v: 99,
      sender: "node2@ghost",
      state: presence_state.new("node2@ghost"),
    ),
  )

  // Give the actor time to process (and discard) the unknown version
  process.sleep(50)

  // Track another entry and verify the actor is still alive
  let _ = presence.track(p, "room:lobby", "user:2", "s2", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(2)
}

// ── Resilience: exception raised inside the merge/processing path ─────

/// A valid remote sync can decode successfully yet still crash while the
/// merge result is processed — for example, a user-supplied `on_diff`
/// callback that panics, a mixed-version peer, or a compromised node. The
/// exception must be contained: the shared presence actor stays alive and its
/// state is not partially mutated by the poisoned sync.
pub fn survives_exception_in_processing_path_test() {
  let ps = test_pubsub("processing_crash")

  // Node1's on_diff panics whenever a diff touches "room:poison". Diffs for
  // any other topic pass through untouched, so local tracking still works.
  let config1 =
    presence.default_config("node1")
    |> presence.with_pubsub(ps)
    |> presence.with_on_diff(fn(diff) {
      case presence.diff_joins(diff, "room:poison") {
        [] -> Nil
        _ -> panic as "poisoned diff"
      }
    })
  let assert Ok(p1) = presence.start(config1)

  // Prove the actor is alive and record its state before the poisoned sync.
  let _ =
    presence.track(p1, "room:lobby", "user:safe", "socket-safe", json.null())
  list.length(presence.list(p1, "room:lobby")) |> should.equal(1)

  // Node2 broadcasts a *valid* sync that decodes cleanly but produces a diff
  // touching "room:poison", tripping node1's panicking callback inside the
  // merge/processing path.
  let config2 = test_config(ps, "node2", 50)
  let assert Ok(p2) = presence.start(config2)
  let _ =
    presence.track(p2, "room:poison", "user:boom", "socket-boom", json.null())

  // Give node1 time to receive and reject several broadcasts of the poison.
  process.sleep(200)

  // The actor is still alive: a fresh local track succeeds.
  let _ =
    presence.track(p1, "room:lobby", "user:safe2", "socket-safe2", json.null())
  list.length(presence.list(p1, "room:lobby")) |> should.equal(2)

  // State was not partially mutated: the poisoned sync never merged, so
  // "room:poison" remains empty on node1.
  presence.list(p1, "room:poison") |> should.equal([])
}

pub fn merge_failure_leaves_read_model_unchanged_test() {
  let ps = test_pubsub("merge_failure_read_model")

  let config1 =
    presence.default_config("node1")
    |> presence.with_pubsub(ps)
    |> presence.with_on_diff(fn(diff) {
      case presence.diff_joins(diff, "room:poison") {
        [] -> Nil
        _ -> panic as "poisoned diff"
      }
    })
  let assert Ok(p1) = presence.start(config1)

  // Snapshot the read model for an unrelated topic before the poisoned sync.
  let _ =
    presence.track(p1, "room:lobby", "user:safe", "socket-safe", json.null())
  let before_entries = presence.list(p1, "room:lobby")
  let before_count = presence.count(p1, "room:lobby")

  let config2 = test_config(ps, "node2", 50)
  let assert Ok(p2) = presence.start(config2)
  let _ =
    presence.track(p2, "room:poison", "user:boom", "socket-boom", json.null())

  // Give node1 time to receive and reject the poisoned broadcast.
  process.sleep(200)

  // The read model for the untouched topic is byte-for-byte unchanged.
  presence.list(p1, "room:lobby") |> should.equal(before_entries)
  presence.count(p1, "room:lobby") |> should.equal(before_count)
  // The poisoned topic's read model was never published in the first
  // place -- it reads empty because the merge was rejected before any
  // ETS write happened, not because of a later prune or partial write.
  presence.list(p1, "room:poison") |> should.equal([])
  presence.count(p1, "room:poison") |> should.equal(0)
}

// ── Helper to drain stray messages ──────────────────────────────────

fn drain_mailbox() -> Nil {
  let selector =
    process.new_selector()
    |> process.select_other(fn(_msg) { True })

  case process.selector_receive(from: selector, within: 10) {
    Ok(_) -> drain_mailbox()
    Error(_) -> Nil
  }
}

// ── Restart safety: incarnation-unique replicas ───────────────────────

pub fn restarted_node_presences_replicate_to_peers_test() {
  let ps = test_pubsub("restart_join")
  let assert Ok(p1) = presence.start(test_config(ps, "node1", 30))
  let assert Ok(p2) = presence.start(test_config(ps, "node2", 30))

  // Seed replication both ways so node2's context covers node1's clocks.
  let _ =
    presence.track(p1, "room:lobby", "user:old", "socket-old", json.null())
  test_helpers.wait_until(
    fn() { list.length(presence.list(p2, "room:lobby")) == 1 },
    2000,
    10,
  )

  // Crash node1 and restart it under the same configured base name.
  test_helpers.kill_presence(p1)
  let assert Ok(p1b) = presence.start(test_config(ps, "node1", 30))

  // A presence tracked by the restarted incarnation must become visible on
  // node2. Without incarnation-unique replicas, node2's causal context
  // already covered the reused clocks and silently dropped this join.
  let _ =
    presence.track(p1b, "room:lobby", "user:new", "socket-new", json.null())
  test_helpers.wait_until(
    fn() {
      presence.list(p2, "room:lobby")
      |> list.any(fn(entry) { entry.key == "user:new" })
    },
    2000,
    10,
  )
  presence.list(p2, "room:lobby")
  |> list.any(fn(entry) { entry.key == "user:new" })
  |> should.be_true
}

pub fn restart_prunes_previous_incarnations_ghosts_test() {
  let ps = test_pubsub("restart_ghosts")
  let assert Ok(p1) = presence.start(test_config(ps, "node1", 30))
  let assert Ok(p2) = presence.start(test_config(ps, "node2", 30))

  // node1 tracks a presence whose session dies with the node.
  let _ =
    presence.track(p1, "room:lobby", "user:ghost", "socket-dead", json.null())
  test_helpers.wait_until(
    fn() { list.length(presence.list(p2, "room:lobby")) == 1 },
    2000,
    10,
  )

  test_helpers.kill_presence(p1)
  let assert Ok(p1b) = presence.start(test_config(ps, "node1", 30))
  // Give the new incarnation something to gossip so peers observe it.
  let _ =
    presence.track(p1b, "room:lobby", "user:live", "socket-live", json.null())

  // The dead incarnation's entry disappears from the peer once it observes
  // the new incarnation, and it must not resurrect into the restarted node
  // via merges of the peer's state.
  test_helpers.wait_until(
    fn() {
      let on_p2 =
        presence.list(p2, "room:lobby") |> list.map(fn(entry) { entry.key })
      let on_p1b =
        presence.list(p1b, "room:lobby") |> list.map(fn(entry) { entry.key })
      on_p2 == ["user:live"] && on_p1b == ["user:live"]
    },
    3000,
    10,
  )
  presence.list(p2, "room:lobby")
  |> list.map(fn(entry) { entry.key })
  |> should.equal(["user:live"])
  presence.list(p1b, "room:lobby")
  |> list.map(fn(entry) { entry.key })
  |> should.equal(["user:live"])
}

pub fn restart_prune_updates_read_model_count_test() {
  let ps = test_pubsub("restart_prune_count")
  let assert Ok(p1) = presence.start(test_config(ps, "node1", 30))
  let assert Ok(p2) = presence.start(test_config(ps, "node2", 30))

  let _ =
    presence.track(p1, "room:lobby", "user:ghost", "socket-dead", json.null())
  test_helpers.wait_until(
    fn() { presence.count(p2, "room:lobby") == 1 },
    2000,
    10,
  )

  test_helpers.kill_presence(p1)
  let assert Ok(p1b) = presence.start(test_config(ps, "node1", 30))
  let _ =
    presence.track(p1b, "room:lobby", "user:live", "socket-live", json.null())

  // The pruned ghost must not inflate the peer's count once it converges
  // on the restarted incarnation.
  test_helpers.wait_until(
    fn() { presence.count(p2, "room:lobby") == 1 },
    3000,
    10,
  )
  presence.count(p2, "room:lobby") |> should.equal(1)
}

// ── Reads stay responsive while the actor mailbox is busy ────────────
//
// Both tests below hold the actor busy from *inside* a test-supplied
// `with_on_diff` callback rather than any production-only message or API:
// `on_diff` already runs synchronously, on the actor process, before the
// read model is published and before the triggering call replies, so a
// callback that blocks is a legitimate (if deliberately slow) user of the
// existing public API. Synchronization uses subjects exclusively -- the
// test always waits on an `entered` signal sent from inside the callback
// before it reads or asserts anything, so there is no sleep-and-hope: the
// assertions run only once the actor is deterministically known to be
// parked inside the callback.

pub fn reads_stay_responsive_while_actor_mailbox_is_blocked_test() {
  // Fires only for user:2's join, so tracking user:1 below completes and
  // publishes normally; only the second track call blocks the actor.
  let entered = process.new_subject()
  let config =
    presence.default_config("node1")
    |> presence.with_on_diff(fn(diff) {
      let joined_user2 =
        presence.diff_joins(diff, "room:lobby")
        |> list.any(fn(entry) { entry.key == "user:2" })
      case joined_user2 {
        False -> Nil
        True -> {
          let release = process.new_subject()
          process.send(entered, release)
          let assert Ok(_) = process.receive(release, 5000)
          Nil
        }
      }
    })
  let assert Ok(p) = presence.start(config)
  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  // Track user:2 from another process: this call blocks (behind on_diff)
  // until we release it below, so it must not run on the test process.
  let track_done = process.new_subject()
  process.spawn_unlinked(fn() {
    let _ = presence.track(p, "room:lobby", "user:2", "socket-2", json.null())
    process.send(track_done, Nil)
  })

  // Deterministically wait until the actor is parked inside the blocked
  // callback for user:2's diff -- it is now busy in its message handler,
  // ahead of both that diff's read-model publish and its own reply.
  let assert Ok(release) = process.receive(entered, 1000)

  // Reads must stay responsive, and still see the already-published
  // user:1 state, even though the actor's mailbox is busy handling the
  // still-blocked second track call.
  presence.count(p, "room:lobby") |> should.equal(1)
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)
  list.length(presence.get_by_key(p, "room:lobby", "user:1"))
  |> should.equal(1)

  // The second track call genuinely has not returned yet: this is a
  // present-tense check on a fixed synchronization point, not a timing
  // race, since the actor cannot have replied while parked above.
  process.receive(track_done, 0) |> should.equal(Error(Nil))

  // Release the callback and drain completion so it can't bleed into a
  // later test.
  process.send(release, Nil)
  let assert Ok(_) = process.receive(track_done, 1000)
}

// ── track/untrack reply only after the read model is published ───────

pub fn actor_reply_is_ordered_after_read_model_publication_test() {
  let entered = process.new_subject()
  let config =
    presence.default_config("node1")
    |> presence.with_on_diff(fn(_diff) {
      let release = process.new_subject()
      process.send(entered, release)
      let assert Ok(_) = process.receive(release, 5000)
      Nil
    })
  let assert Ok(p) = presence.start(config)

  // `track` blocks (behind on_diff) until released below, so it must run
  // on another process while the test drives the synchronization.
  let track_done = process.new_subject()
  process.spawn_unlinked(fn() {
    let ref = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
    process.send(track_done, ref)
  })

  // Deterministically wait until the actor is parked inside the blocked
  // callback -- it has not yet published the read model or replied.
  let assert Ok(release) = process.receive(entered, 1000)

  // While the callback is blocked, neither the publish nor the reply has
  // happened yet: the tracking call has not returned, and the read model
  // still reports the pre-track state.
  process.receive(track_done, 0) |> should.equal(Error(Nil))
  presence.count(p, "room:lobby") |> should.equal(0)

  // Release the callback so the actor finishes handling `Track`: publish
  // the read model, then reply.
  process.send(release, Nil)
  let assert Ok(_ref) = process.receive(track_done, 1000)

  // The moment `track` returns, its read-model snapshot is already
  // published -- this is a reply-ordering guarantee, not eventual
  // consistency, so no polling is needed here.
  presence.count(p, "room:lobby") |> should.equal(1)
}
