import beryl/presence/state
import gleam/dict
import gleam/json
import gleam/list
import gleam/set
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ── new ──────────────────────────────────────────────────────────────

pub fn new_creates_empty_state_test() {
  let s = state.new("node1")
  state.online_list(s) |> should.equal([])
  s.replica |> should.equal("node1")
}

// ── join ─────────────────────────────────────────────────────────────

pub fn join_makes_user_online_test() {
  let s = state.new("node1")
  let s =
    state.join(s, "pid1", "room:lobby", "user:alice", json.object([
      #("status", json.string("online")),
    ]))

  let entries = state.get_by_topic(s, "room:lobby")
  list.length(entries) |> should.equal(1)
  let assert [#(_pid, "user:alice", _meta)] = entries
}

pub fn join_increments_clock_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "alice", json.object([]))
  let s = state.join(s, "pid2", "room:lobby", "bob", json.object([]))

  let entries = state.get_by_topic(s, "room:lobby")
  list.length(entries) |> should.equal(2)
}

pub fn join_multiple_topics_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "alice", json.object([]))
  let s = state.join(s, "pid1", "room:private", "alice", json.object([]))

  state.get_by_topic(s, "room:lobby") |> list.length |> should.equal(1)
  state.get_by_topic(s, "room:private") |> list.length |> should.equal(1)
}

// ── leave ────────────────────────────────────────────────────────────

pub fn leave_removes_user_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "alice", json.object([]))
  let s = state.leave(s, "pid1", "room:lobby", "alice")

  state.get_by_topic(s, "room:lobby") |> should.equal([])
}

pub fn leave_nonexistent_is_noop_test() {
  let s = state.new("node1")
  let s = state.leave(s, "pid1", "room:lobby", "alice")
  state.online_list(s) |> should.equal([])
}

pub fn leave_all_by_pid_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "alice", json.object([]))
  let s = state.join(s, "pid1", "room:private", "alice", json.object([]))
  let s = state.join(s, "pid2", "room:lobby", "bob", json.object([]))

  let s = state.leave_by_pid(s, "pid1")

  // pid1's entries gone, pid2's entry remains
  state.online_list(s) |> list.length |> should.equal(1)
  state.get_by_topic(s, "room:private") |> should.equal([])
}

// ── merge ────────────────────────────────────────────────────────────

pub fn merge_adds_remote_entries_test() {
  // Node A has alice, Node B has bob
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let b = state.join(b, "pid2", "room:lobby", "bob", json.object([]))

  // Merge B into A
  let #(merged, _diff) = state.merge(a, b)

  // A should now see both alice and bob
  state.get_by_topic(merged, "room:lobby") |> list.length |> should.equal(2)
}

pub fn merge_is_idempotent_test() {
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let b = state.join(b, "pid2", "room:lobby", "bob", json.object([]))

  // Merge twice should not duplicate
  let #(merged, _) = state.merge(a, b)
  let #(merged2, _) = state.merge(merged, b)

  state.get_by_topic(merged2, "room:lobby") |> list.length |> should.equal(2)
}

pub fn merge_observes_remote_removals_test() {
  // Node A and B both know about alice
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([]))

  // B merges A's state to learn about alice
  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // A removes alice locally
  let a = state.leave(a, "pid1", "room:lobby", "alice")

  // B merges A again — should observe the removal
  let #(merged, _) = state.merge(b, a)
  state.get_by_topic(merged, "room:lobby") |> should.equal([])
}

pub fn merge_add_wins_over_concurrent_remove_test() {
  // A has alice, B learns about alice
  let a = state.new("node_a")
  let a =
    state.join(a, "pid1", "room:lobby", "alice", json.object([
      #("v", json.int(1)),
    ]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // Concurrently: A removes alice, B re-adds alice
  let a = state.leave(a, "pid1", "room:lobby", "alice")
  let b =
    state.join(b, "pid1", "room:lobby", "alice", json.object([
      #("v", json.int(2)),
    ]))

  // When A merges B, alice should be present (add wins)
  let #(merged, _) = state.merge(a, b)
  state.get_by_topic(merged, "room:lobby") |> list.length |> should.equal(1)
}

pub fn merge_returns_diff_with_joins_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let b = state.join(b, "pid1", "room:lobby", "bob", json.object([]))

  let #(_merged, diff) = state.merge(a, b)

  // Diff should show bob as a join
  case dict.get(diff.joins, "room:lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

pub fn merge_returns_diff_with_leaves_test() {
  // A knows about bob (from previous merge with B)
  let a = state.new("node_a")
  let b = state.new("node_b")
  let b = state.join(b, "pid1", "room:lobby", "bob", json.object([]))

  let #(a, _) = state.merge(a, b)

  // B removes bob
  let b = state.leave(b, "pid1", "room:lobby", "bob")

  // Merge again — diff should show bob as a leave
  let #(_merged, diff) = state.merge(a, b)
  case dict.get(diff.leaves, "room:lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

pub fn merge_three_nodes_test() {
  // Three nodes, each with one user
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let b = state.join(b, "p2", "room:lobby", "bob", json.object([]))

  let c = state.new("node_c")
  let c = state.join(c, "p3", "room:lobby", "carol", json.object([]))

  // Merge all into A via two hops
  let #(a, _) = state.merge(a, b)
  let #(a, _) = state.merge(a, c)

  state.get_by_topic(a, "room:lobby") |> list.length |> should.equal(3)
}

// ── Phoenix-inspired merge tests ────────────────────────────────────
// Ported from Phoenix.Tracker.StateTest

/// Phoenix test: "users from other servers merge" — full lifecycle
/// merge, idempotent re-merge, observe remove, new join after remove,
/// and metadata update via leave+join
pub fn phoenix_full_merge_lifecycle_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))
  let b = state.join(b, "pid_bob", "lobby", "bob", json.object([]))

  // Merge B into A — bob appears as join
  let #(a, diff) = state.merge(a, b)
  state.online_list(a) |> list.length |> should.equal(2)
  case dict.get(diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }

  // Merge B into A again — idempotent, no new events
  let #(a2, diff2) = state.merge(a, b)
  dict.size(diff2.joins) |> should.equal(0)
  dict.size(diff2.leaves) |> should.equal(0)
  state.online_list(a2) |> list.length |> should.equal(2)

  // Merge A into B — alice appears as join
  let #(b, diff3) = state.merge(b, a)
  case dict.get(diff3.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
  // Re-merge is idempotent
  let #(_b2, diff4) = state.merge(b, a)
  dict.size(diff4.joins) |> should.equal(0)

  // A removes alice, B observes via merge
  let a = state.leave(a, "pid_alice", "lobby", "alice")
  let #(b, diff5) = state.merge(b, a)
  case dict.get(diff5.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
  state.online_list(b) |> list.length |> should.equal(1)

  // B adds carol
  let b = state.join(b, "pid_carol", "lobby", "carol", json.object([]))
  state.online_list(b) |> list.length |> should.equal(2)

  // A merges B — gets carol
  let #(a, diff6) = state.merge(a, b)
  case dict.get(diff6.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }

  // After full sync both nodes agree
  state.online_list(a) |> list.length |> should.equal(
    state.online_list(b) |> list.length,
  )
}

/// Phoenix test: metadata update via leave+join (leave_join pattern)
pub fn phoenix_update_via_leave_join_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let b =
    state.join(b, "pid_carol", "lobby", "carol", json.object([
      #("status", json.string("online")),
    ]))

  // Sync A with B
  let #(a, _) = state.merge(a, b)

  // B updates carol by leaving then rejoining with new meta
  let b = state.leave(b, "pid_carol", "lobby", "carol")
  let b =
    state.join(b, "pid_carol", "lobby", "carol", json.object([
      #("status", json.string("away")),
    ]))

  // Merge into A — should see a leave and a join for carol
  let #(_a, diff) = state.merge(a, b)
  case dict.get(diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
  case dict.get(diff.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

/// Phoenix test: "basic netsplit" — replica down during mutations,
/// merge is no-op while down, replica_up restores
pub fn phoenix_netsplit_with_mutations_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))
  let b = state.join(b, "pid_bob", "lobby", "bob", json.object([]))

  // Sync
  let #(a, _) = state.merge(a, b)
  state.online_list(a) |> list.length |> should.equal(2)

  // A does some mutations
  let a = state.join(a, "pid_carol", "lobby", "carol", json.object([]))
  let a = state.leave(a, "pid_alice", "lobby", "alice")
  let a = state.join(a, "pid_david", "lobby", "david", json.object([]))

  // Netsplit: A marks B as down
  let #(a, down_diff) = state.replica_down(a, "node_b")
  // bob should show as a leave
  case dict.get(down_diff.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
  // Only carol and david visible (alice left, bob is down)
  state.online_list(a) |> list.length |> should.equal(2)

  // Merge while down is no-op for visibility
  let #(a, noop_diff) = state.merge(a, b)
  dict.size(noop_diff.joins) |> should.equal(0)
  state.online_list(a) |> list.length |> should.equal(2)

  // Heal: A marks B as up — bob reappears
  let #(a, up_diff) = state.replica_up(a, "node_b")
  case dict.get(up_diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
  // carol, david, bob
  state.online_list(a) |> list.length |> should.equal(3)
}

/// Phoenix test: "joins are observed via other node" (3-node with netsplit)
pub fn phoenix_joins_via_intermediate_node_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let c = state.new("node_c")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))

  // C learns about alice from A
  let #(c, _) = state.merge(c, a)
  state.get_by_topic(c, "lobby") |> list.length |> should.equal(1)

  // Netsplit between A and C
  let #(a, _) = state.replica_down(a, "node_c")
  let #(c, _) = state.replica_down(c, "node_a")

  // A adds bob
  let a = state.join(a, "pid_bob", "lobby", "bob", json.object([]))

  // B merges A's full state — gets both alice and bob
  let #(b, _) = state.merge(b, a)
  state.get_by_topic(b, "lobby") |> list.length |> should.equal(2)

  // C merges B — should get bob (which C hasn't seen yet)
  let #(_c, diff) = state.merge(c, b)
  case dict.get(diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

/// Phoenix test: "removes are observed via other node" (3-node with netsplit)
/// Tests that removes propagate through an intermediate node even during netsplit
pub fn phoenix_removes_via_intermediate_node_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let c = state.new("node_c")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))

  // All nodes learn about alice
  let #(b, _) = state.merge(b, a)
  let #(c, _) = state.merge(c, a)

  // B adds bob
  let b = state.join(b, "pid_bob", "lobby", "bob", json.object([]))

  // A and C learn about bob
  let #(a, _) = state.merge(a, b)
  let #(c, _) = state.merge(c, b)
  state.get_by_topic(c, "lobby") |> list.length |> should.equal(2)

  // Netsplit between A and C (B can talk to both)
  let #(a, _) = state.replica_down(a, "node_c")
  let #(c, _) = state.replica_down(c, "node_a")

  // A removes alice
  let a = state.leave(a, "pid_alice", "lobby", "alice")

  // B observes remove via A
  let #(b, _) = state.merge(b, a)

  // C observes remove via B (not directly from A due to netsplit)
  let #(_c, diff) = state.merge(c, b)
  case dict.get(diff.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

// ── extract (delta) ──────────────────────────────────────────────────

pub fn extract_produces_delta_for_new_replica_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))
  let a = state.join(a, "p2", "room:lobby", "bob", json.object([]))

  let b = state.new("node_b")

  // Extract what B needs from A (everything, since B has empty context)
  let delta = state.extract(a, b.replica, b.context)

  // Delta should contain both entries
  dict.size(delta.values) |> should.equal(2)
}

pub fn extract_returns_full_state_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // Extract returns full state — merge handles deduplication
  let extracted = state.extract(a, b.replica, b.context)
  dict.size(extracted.values) |> should.equal(1)
}

pub fn extract_includes_all_entries_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))
  let a = state.join(a, "p2", "room:lobby", "bob", json.object([]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  // A adds a third entry
  let a = state.join(a, "p3", "room:lobby", "carol", json.object([]))

  // Extract returns all 3 entries (full state)
  let extracted = state.extract(a, b.replica, b.context)
  dict.size(extracted.values) |> should.equal(3)
}

/// Phoenix test: extract-based merge workflow (mirrors Phoenix's merge(a, extract(b, ...)))
pub fn phoenix_extract_merge_workflow_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))
  let b = state.join(b, "pid_bob", "lobby", "bob", json.object([]))

  // Merge using extract (like Phoenix does)
  let delta_b = state.extract(b, a.replica, a.context)
  let #(a, diff) = state.merge(a, delta_b)
  state.online_list(a) |> list.length |> should.equal(2)
  case dict.get(diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }

  // Second extract-merge is idempotent
  let delta_b2 = state.extract(b, a.replica, a.context)
  let #(a2, diff2) = state.merge(a, delta_b2)
  dict.size(diff2.joins) |> should.equal(0)
  dict.size(diff2.leaves) |> should.equal(0)
  state.online_list(a2) |> list.length |> should.equal(2)
}

/// Phoenix test: extract-based remove observation
pub fn phoenix_extract_observes_remove_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let a = state.join(a, "pid_alice", "lobby", "alice", json.object([]))
  let b = state.join(b, "pid_bob", "lobby", "bob", json.object([]))

  // Sync both directions
  let #(a, _) = state.merge(a, state.extract(b, a.replica, a.context))
  let #(b, _) = state.merge(b, state.extract(a, b.replica, b.context))

  // A removes alice
  let a = state.leave(a, "pid_alice", "lobby", "alice")

  // B merges A's extract — should observe alice's removal
  let #(b, diff) = state.merge(b, state.extract(a, b.replica, b.context))
  case dict.get(diff.leaves, "lobby") {
    Ok(leaves) -> list.length(leaves) |> should.equal(1)
    Error(_) -> should.fail()
  }
  state.online_list(b) |> list.length |> should.equal(1)
}

/// Phoenix test: "get_by_topic" with multiple replicas and down/up filtering
pub fn phoenix_get_by_topic_with_replica_status_test() {
  let s1 = state.new("node1")
  let s2 = state.new("node2")
  let s3 = state.new("node3")

  // Each node adds entries
  let s1 = state.join(s1, "pid1", "topic", "key1", json.object([]))
  let s1 = state.join(s1, "pid1", "topic", "key2", json.object([]))
  let s2 = state.join(s2, "pid2", "topic", "user2", json.object([]))
  let s3 = state.join(s3, "pid3", "topic", "user3", json.object([]))

  // s1 sees only local entries
  state.get_by_topic(s1, "topic") |> list.length |> should.equal(2)

  // Merge all into s1
  let #(s1, _) = state.merge(s1, s2)
  let #(s1, _) = state.merge(s1, s3)

  // All 4 entries visible
  state.get_by_topic(s1, "topic") |> list.length |> should.equal(4)

  // One replica down — 3 entries visible
  let #(s1, _) = state.replica_down(s1, "node2")
  state.get_by_topic(s1, "topic") |> list.length |> should.equal(3)

  // Two replicas down — 2 entries visible (only local)
  let #(s1, _) = state.replica_down(s1, "node3")
  state.get_by_topic(s1, "topic") |> list.length |> should.equal(2)

  // Different topic returns empty
  state.get_by_topic(s1, "another:topic") |> should.equal([])
}

/// Phoenix test: "get_by_key" with multiple pids for same key
pub fn phoenix_get_by_key_test() {
  let s = state.new("node1")

  state.get_by_key(s, "topic", "key1") |> should.equal([])

  let s =
    state.join(s, "pid1", "topic", "key1", json.object([
      #("device", json.string("browser")),
    ]))
  let s =
    state.join(s, "pid2", "topic", "key1", json.object([
      #("device", json.string("ios")),
    ]))
  let s =
    state.join(s, "pid2", "topic", "key2", json.object([
      #("device", json.string("ios")),
    ]))

  // Two entries for key1
  state.get_by_key(s, "topic", "key1") |> list.length |> should.equal(2)

  // Different topic/key returns empty
  state.get_by_key(s, "another_topic", "key1") |> should.equal([])
  state.get_by_key(s, "topic", "another_key") |> should.equal([])
}

/// Phoenix test: "remove_down_replicas" — permanent deletion
pub fn phoenix_remove_down_replicas_test() {
  let s1 = state.new("node1")
  let s2 = state.new("node2")

  let s1 = state.join(s1, "pid_alice", "lobby", "alice", json.object([]))
  let s2 = state.join(s2, "pid_bob", "lobby", "bob", json.object([]))

  // Sync
  let #(s2, _) = state.merge(s2, s1)
  state.online_list(s2) |> list.length |> should.equal(2)

  // Mark node1 as down
  let #(s2, _) = state.replica_down(s2, "node1")

  // Permanently remove node1
  let s2 = state.remove_down_replicas(s2, "node1")

  // Even after replica_up, alice is gone permanently
  let #(s2, _) = state.replica_up(s2, "node1")
  state.online_list(s2) |> list.length |> should.equal(1)
}

// ── edge cases ───────────────────────────────────────────────────────

pub fn clocks_returns_vector_clock_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:1", "k1", json.object([]))
  let a = state.join(a, "p2", "room:1", "k2", json.object([]))

  let clocks = state.clocks(a)
  case dict.get(clocks, "node_a") {
    Ok(2) -> Nil
    _ -> should.fail()
  }
}

pub fn compact_reduces_clouds_test() {
  // After local joins, context should be fully compacted (no clouds)
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:1", "k1", json.object([]))
  let a = state.join(a, "p2", "room:1", "k2", json.object([]))

  let compacted = state.compact(a)
  case dict.get(compacted.clouds, "node_a") {
    Ok(cloud) -> set.size(cloud) |> should.equal(0)
    Error(_) -> Nil
  }
}

pub fn merge_with_empty_state_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:1", "k1", json.object([]))

  let empty = state.new("node_b")

  // Merging empty into non-empty should be a no-op
  let #(merged, diff) = state.merge(a, empty)
  state.get_by_topic(merged, "room:1") |> list.length |> should.equal(1)
  dict.size(diff.joins) |> should.equal(0)
  dict.size(diff.leaves) |> should.equal(0)
}

pub fn get_by_key_multiple_pids_test() {
  let a = state.new("node_a")
  let a =
    state.join(a, "pid1", "room:lobby", "user:alice", json.object([
      #("device", json.string("desktop")),
    ]))
  let a =
    state.join(a, "pid2", "room:lobby", "user:alice", json.object([
      #("device", json.string("mobile")),
    ]))

  let results = state.get_by_key(a, "room:lobby", "user:alice")
  list.length(results) |> should.equal(2)
}

pub fn leave_only_removes_matching_entry_test() {
  let a = state.new("node_a")
  let a = state.join(a, "pid1", "room:lobby", "alice", json.object([]))
  let a = state.join(a, "pid1", "room:lobby", "bob", json.object([]))
  let a = state.leave(a, "pid1", "room:lobby", "alice")

  state.get_by_topic(a, "room:lobby") |> list.length |> should.equal(1)
}

pub fn joins_propagate_through_intermediate_node_test() {
  // A -> B -> C chain: A's join should reach C via B
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  let c = state.new("node_c")
  let #(c, _) = state.merge(c, b)

  // C should see alice
  state.get_by_topic(c, "room:lobby") |> list.length |> should.equal(1)
}

pub fn removes_propagate_through_intermediate_node_test() {
  // All three nodes sync, then A removes, propagate via B to C
  let a = state.new("node_a")
  let a = state.join(a, "p1", "room:lobby", "alice", json.object([]))

  let b = state.new("node_b")
  let #(b, _) = state.merge(b, a)

  let c = state.new("node_c")
  let #(c, _) = state.merge(c, b)

  // A removes alice
  let a = state.leave(a, "p1", "room:lobby", "alice")

  // Propagate: A -> B -> C
  let #(b, _) = state.merge(b, a)
  let #(c, _) = state.merge(c, b)

  state.get_by_topic(c, "room:lobby") |> should.equal([])
}

/// Phoenix test: clocks advance correctly through merges
pub fn phoenix_clocks_advance_through_merge_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let a = state.join(a, "p1", "lobby", "alice", json.object([]))
  let b = state.join(b, "p2", "lobby", "bob", json.object([]))

  let #(b, _) = state.merge(b, a)

  let clocks = state.clocks(b)
  case dict.get(clocks, "node_a") {
    Ok(1) -> Nil
    _ -> should.fail()
  }
  case dict.get(clocks, "node_b") {
    Ok(1) -> Nil
    _ -> should.fail()
  }

  // A leaves then rejoins — clock advances to 2
  let a = state.leave(a, "p1", "lobby", "alice")
  // leave doesn't advance clock, but re-join does:
  let a = state.join(a, "p1", "lobby", "alice", json.object([]))

  let #(b, _) = state.merge(b, a)
  case dict.get(state.clocks(b), "node_a") {
    Ok(2) -> Nil
    _ -> should.fail()
  }
}

/// All clouds should be empty after merge (fully compacted)
pub fn phoenix_clouds_empty_after_merge_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")

  let a = state.join(a, "p1", "lobby", "alice", json.object([]))
  let b = state.join(b, "p2", "lobby", "bob", json.object([]))

  let #(b, _) = state.merge(b, a)

  // All clouds should be compacted away
  dict.to_list(b.clouds)
  |> list.all(fn(kv) {
    let #(_, cloud) = kv
    set.is_empty(cloud)
  })
  |> should.be_true
}
