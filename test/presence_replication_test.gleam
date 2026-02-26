import beryl/presence
import beryl/pubsub
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ── Helper ──────────────────────────────────────────────────────────

/// Create a unique PubSub scope per test to avoid cross-test interference
fn test_pubsub(name: String) -> pubsub.PubSub {
  let config = pubsub.config_with_scope("test_presence_repl_" <> name)
  let assert Ok(ps) = pubsub.start(config)
  ps
}

fn test_config(
  ps: pubsub.PubSub,
  replica: String,
  interval_ms: Int,
) -> presence.Config {
  presence.Config(
    pubsub: Some(ps),
    replica: replica,
    broadcast_interval_ms: interval_ms,
  )
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

  // Wait for a broadcast tick to fire (interval is 50ms)
  process.sleep(150)

  // Check that we received a PubSub message
  let selector =
    process.new_selector()
    |> process.select_other(fn(_msg) { True })

  let result = process.selector_receive(from: selector, within: 200)
  should.be_ok(result)

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
  process.sleep(300)

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

  // Wait for several broadcast ticks
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
    presence.Config(
      pubsub: Some(ps),
      replica: "node1",
      broadcast_interval_ms: 0,
    )
  let assert Ok(p1) = presence.start(config1)

  // Node2 with broadcasting enabled
  let config2 = test_config(ps, "node2", 50)
  let assert Ok(p2) = presence.start(config2)

  // Track on node2
  let _ = presence.track(p2, "room:lobby", "user:2", "socket-2", json.null())

  // Wait for node2's broadcast to reach node1
  process.sleep(200)

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

  // Wait for convergence (multiple broadcast ticks)
  process.sleep(500)

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
