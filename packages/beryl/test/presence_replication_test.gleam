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
  pubsub.subscribe(ps, "beryl:presence:sync")

  // Poll until a PubSub message arrives from the broadcast tick
  let selector =
    process.new_selector()
    |> process.select_other(fn(_msg) { True })

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

  // Clean up: unsubscribe to avoid polluting other tests
  pubsub.unsubscribe(ps, "beryl:presence:sync")

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

/// Kill a presence actor's process, simulating a crash without cleanup.
fn kill_presence(p: presence.Presence) -> Nil {
  let assert Ok(pid) = process.subject_owner(presence.subject(p))
  // The actor is linked to this (test) process; unlink before killing so
  // the exit signal does not take the test runner down with it.
  process.unlink(pid)
  process.kill(pid)
  // Wait for the process to actually be gone.
  test_helpers.wait_until(fn() { !process.is_alive(pid) }, 1000, 5)
  Nil
}

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
  kill_presence(p1)
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

  kill_presence(p1)
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
