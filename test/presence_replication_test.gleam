import beryl/presence
import beryl/presence/state
import beryl/presence/state_json
import beryl/pubsub
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import test_helpers

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
    on_diff: None,
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
    presence.Config(
      pubsub: Some(ps),
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: None,
    )
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
  let _ = presence.track(p1, "room:lobby", "user:1", "socket-1", json.null())

  // Wait for convergence -- both should see the entry
  test_helpers.wait_until(
    fn() { list.length(presence.list(p2, "room:lobby")) == 1 },
    2000,
    20,
  )

  // Untrack on node1
  presence.untrack(p1, "room:lobby", "user:1", "socket-1")

  // Wait for the untrack to propagate via next broadcast tick
  test_helpers.wait_until(
    fn() { presence.list(p2, "room:lobby") == [] },
    2000,
    20,
  )

  // Node2 should see the removal
  list.length(presence.list(p2, "room:lobby")) |> should.equal(0)
}

// ── Version field validation ─────────────────────────────────────────

pub fn parse_sync_envelope_rejects_unknown_version_test() {
  let s = state.new("remote")
  let envelope =
    json.object([
      #("v", json.int(2)),
      #("sender", json.string("remote")),
      #("state", state_json.encode(s)),
    ])
    |> json.to_string

  presence.parse_sync_envelope(envelope) |> should.be_error
}

pub fn parse_sync_envelope_accepts_version_1_test() {
  let s = state.new("remote")
  let envelope =
    json.object([
      #("v", json.int(1)),
      #("sender", json.string("remote")),
      #("state", state_json.encode(s)),
    ])
    |> json.to_string

  presence.parse_sync_envelope(envelope) |> should.be_ok
}

pub fn parse_sync_envelope_rejects_missing_version_test() {
  let s = state.new("remote")
  let envelope =
    json.object([
      #("sender", json.string("remote")),
      #("state", state_json.encode(s)),
    ])
    |> json.to_string

  presence.parse_sync_envelope(envelope) |> should.be_error
}

// ── Resilience: malformed sync messages ──────────────────────────────

pub fn survives_empty_string_payload_test() {
  let ps = test_pubsub("malform_empty")
  let config =
    presence.Config(
      pubsub: Some(ps),
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: None,
    )
  let assert Ok(p) = presence.start(config)

  // Track an entry to prove the actor is alive
  let _ = presence.track(p, "room:lobby", "user:1", "s1", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)

  // Send malformed message: empty string payload
  pubsub.broadcast(ps, "beryl:presence:sync", "presence_sync", json.string(""))

  // Give the actor time to process the malformed message
  process.sleep(50)

  // Track another entry and verify the actor is still alive
  let _ = presence.track(p, "room:lobby", "user:2", "s2", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(2)
}

pub fn survives_malformed_json_payload_test() {
  let ps = test_pubsub("malform_json")
  let config =
    presence.Config(
      pubsub: Some(ps),
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: None,
    )
  let assert Ok(p) = presence.start(config)

  let _ = presence.track(p, "room:lobby", "user:1", "s1", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)

  // Send malformed message: invalid JSON content
  pubsub.broadcast(
    ps,
    "beryl:presence:sync",
    "presence_sync",
    json.string("not json{{}"),
  )

  process.sleep(50)

  let _ = presence.track(p, "room:lobby", "user:2", "s2", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(2)
}

pub fn survives_wrong_schema_payload_test() {
  let ps = test_pubsub("malform_schema")
  let config =
    presence.Config(
      pubsub: Some(ps),
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: None,
    )
  let assert Ok(p) = presence.start(config)

  let _ = presence.track(p, "room:lobby", "user:1", "s1", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)

  // Send valid JSON with wrong schema (missing required fields)
  pubsub.broadcast(
    ps,
    "beryl:presence:sync",
    "presence_sync",
    json.object([#("foo", json.string("bar"))]),
  )

  process.sleep(50)

  let _ = presence.track(p, "room:lobby", "user:2", "s2", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(2)
}

pub fn survives_wrong_types_payload_test() {
  let ps = test_pubsub("malform_types")
  let config =
    presence.Config(
      pubsub: Some(ps),
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: None,
    )
  let assert Ok(p) = presence.start(config)

  let _ = presence.track(p, "room:lobby", "user:1", "s1", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)

  // Send valid JSON with correct keys but wrong types
  pubsub.broadcast(
    ps,
    "beryl:presence:sync",
    "presence_sync",
    json.object([
      #("v", json.string("one")),
      #("sender", json.int(123)),
      #("state", json.null()),
    ]),
  )

  process.sleep(50)

  let _ = presence.track(p, "room:lobby", "user:2", "s2", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(2)
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
