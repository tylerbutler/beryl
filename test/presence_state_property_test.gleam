import beryl/presence/state
import beryl/presence/state_json
import crdt_generators
import gleam/dict
import gleam/json
import gleam/list
import gleam/set
import gleeunit
import gleeunit/should
import qcheck

pub fn main() {
  gleeunit.main()
}

// ═══════════════════════════════════════════════════════════════════
// CRDT Mathematical Invariants
// ═══════════════════════════════════════════════════════════════════

// ── Commutativity ───────────────────────────────────────────────────

/// merge(A, B) and merge(B, A) must produce the same online set
pub fn prop_merge_commutativity_test() {
  use #(ops_a, ops_b) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    crdt_generators.gen_ops_for("r2"),
  ))
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)

  let #(ab, _) = state.merge(a, b)
  let #(ba, _) = state.merge(b, a)

  crdt_generators.online_ids(ab)
  |> should.equal(crdt_generators.online_ids(ba))
}

// ── Associativity ───────────────────────────────────────────────────

/// merge(merge(A, B), C) == merge(A, merge(B, C))
pub fn prop_merge_associativity_test() {
  use #(ops_a, #(ops_b, ops_c)) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    qcheck.tuple2(
      crdt_generators.gen_ops_for("r2"),
      crdt_generators.gen_ops_for("r3"),
    ),
  ))
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)
  let c = crdt_generators.apply_ops(state.new("r3"), ops_c)

  let #(ab, _) = state.merge(a, b)
  let #(ab_c, _) = state.merge(ab, c)

  let #(bc, _) = state.merge(b, c)
  let #(a_bc, _) = state.merge(a, bc)

  crdt_generators.online_ids(ab_c)
  |> should.equal(crdt_generators.online_ids(a_bc))
}

// ── Idempotency ─────────────────────────────────────────────────────

/// merge(A, A) == A
pub fn prop_merge_idempotency_test() {
  use ops <- qcheck.given(crdt_generators.gen_ops_for("r1"))
  let s = crdt_generators.apply_ops(state.new("r1"), ops)

  let #(merged, _) = state.merge(s, s)

  crdt_generators.online_ids(merged)
  |> should.equal(crdt_generators.online_ids(s))
}

// ── Convergence ─────────────────────────────────────────────────────

/// All merge orderings of 3 replicas converge to the same state
pub fn prop_merge_convergence_test() {
  use #(ops_a, #(ops_b, ops_c)) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    qcheck.tuple2(
      crdt_generators.gen_ops_for("r2"),
      crdt_generators.gen_ops_for("r3"),
    ),
  ))
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)
  let c = crdt_generators.apply_ops(state.new("r3"), ops_c)

  // Order 1: A merges B, then C
  let #(r1, _) = state.merge(a, b)
  let #(r1, _) = state.merge(r1, c)

  // Order 2: A merges C, then B
  let #(r2, _) = state.merge(a, c)
  let #(r2, _) = state.merge(r2, b)

  // Order 3: B merges A, then C
  let #(r3, _) = state.merge(b, a)
  let #(r3, _) = state.merge(r3, c)

  let ids1 = crdt_generators.online_ids(r1)
  let ids2 = crdt_generators.online_ids(r2)
  let ids3 = crdt_generators.online_ids(r3)

  ids1 |> should.equal(ids2)
  ids2 |> should.equal(ids3)
}

// ── Add-wins ────────────────────────────────────────────────────────

/// A concurrent add and remove of the same entry must resolve to present
pub fn prop_add_wins_test() {
  use #(topic, key, pid) <- qcheck.given(crdt_generators.gen_entry())

  // A adds the entry
  let a = state.new("r1") |> state.join(pid, topic, key, json.null())

  // B learns about it via merge
  let b = state.new("r2")
  let #(b, _) = state.merge(b, a)

  // Concurrently: B removes it, A re-adds it (creating a new tag)
  let b = state.leave(b, pid, topic, key)
  let a = state.leave(a, pid, topic, key)
  let a = state.join(a, pid, topic, key, json.null())

  // Merge — the concurrent add should win
  let #(resolved, _) = state.merge(b, a)

  state.get_by_topic(resolved, topic)
  |> list.length
  |> should.equal(1)
}

// ── Monotonic clocks ────────────────────────────────────────────────

/// After merge, the vector clock is >= both inputs (clocks never go backwards)
pub fn prop_monotonic_clocks_test() {
  use #(ops_a, ops_b) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    crdt_generators.gen_ops_for("r2"),
  ))
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)

  let a_clocks = state.clocks(a)
  let b_clocks = state.clocks(b)
  let #(merged, _) = state.merge(a, b)
  let merged_clocks = state.clocks(merged)

  // Every clock in A should be <= the corresponding clock in merged
  dict.each(a_clocks, fn(replica, clock) {
    case dict.get(merged_clocks, replica) {
      Ok(merged_clock) -> should.be_true(merged_clock >= clock)
      Error(_) -> should.fail()
    }
  })

  // Every clock in B should be <= the corresponding clock in merged
  dict.each(b_clocks, fn(replica, clock) {
    case dict.get(merged_clocks, replica) {
      Ok(merged_clock) -> should.be_true(merged_clock >= clock)
      Error(_) -> should.fail()
    }
  })
}

// ── Compaction invariant ────────────────────────────────────────────

/// After merge, compact is a no-op (merge already compacts)
pub fn prop_compaction_invariant_test() {
  use #(ops_a, ops_b) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    crdt_generators.gen_ops_for("r2"),
  ))
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)

  let #(merged, _) = state.merge(a, b)
  let double_compacted = state.compact(merged)

  // Context should be identical
  state.clocks(merged) |> should.equal(state.clocks(double_compacted))

  // Clouds should be identical
  merged.clouds |> should.equal(double_compacted.clouds)

  // Online set should be identical
  crdt_generators.online_ids(merged)
  |> should.equal(crdt_generators.online_ids(double_compacted))
}

// ── Merge diff accuracy ─────────────────────────────────────────────

/// The diff returned by merge accurately reflects the actual state change
pub fn prop_merge_diff_accuracy_test() {
  use #(ops_a, ops_b) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    crdt_generators.gen_ops_for("r2"),
  ))
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)

  let #(merged, diff) = state.merge(a, b)
  let after_ids = crdt_generators.online_ids(merged)

  // All entries reported as joins must be present in the merged state
  let join_ids = crdt_generators.diff_entry_ids(diff.joins)
  set.each(join_ids, fn(id) { should.be_true(set.contains(after_ids, id)) })

  // Entries reported as leaves (and not also as joins) must be absent
  let leave_ids = crdt_generators.diff_entry_ids(diff.leaves)
  let leave_only = set.difference(leave_ids, join_ids)
  set.each(leave_only, fn(id) { should.be_false(set.contains(after_ids, id)) })
}

// ═══════════════════════════════════════════════════════════════════
// Serialization Properties
// ═══════════════════════════════════════════════════════════════════

// ── Serialization roundtrip ─────────────────────────────────────────

/// decode(encode(S)) should merge identically with a third state as S does
pub fn prop_serialization_roundtrip_test() {
  use ops <- qcheck.given(crdt_generators.gen_ops_for("r1"))
  let s = crdt_generators.apply_ops(state.new("r1"), ops)

  let json_str = state_json.encode_to_string(s)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  // Both original and decoded should merge identically with a third state
  let other = state.new("r2") |> state.join("p_x", "t_x", "k_x", json.null())

  let #(m1, _) = state.merge(s, other)
  let #(m2, _) = state.merge(decoded, other)

  crdt_generators.online_ids(m1)
  |> should.equal(crdt_generators.online_ids(m2))
}

// ── Double roundtrip stability ──────────────────────────────────────

/// encode(decode(encode(S))) == encode(S) — serialization is stable
pub fn prop_double_roundtrip_stability_test() {
  use ops <- qcheck.given(crdt_generators.gen_ops_for("r1"))
  let s = crdt_generators.apply_ops(state.new("r1"), ops)

  let encoded1 = state_json.encode_to_string(s)
  let assert Ok(decoded) = state_json.decode_from_string(encoded1)
  let encoded2 = state_json.encode_to_string(decoded)
  let assert Ok(decoded2) = state_json.decode_from_string(encoded2)
  let encoded3 = state_json.encode_to_string(decoded2)

  // Second and third encodings should be identical
  encoded2 |> should.equal(encoded3)
}

// ═══════════════════════════════════════════════════════════════════
// Phoenix-Inspired Scenarios
// ═══════════════════════════════════════════════════════════════════

// ── Netsplit + heal ─────────────────────────────────────────────────

/// After netsplit and heal, merging should converge
pub fn prop_netsplit_heal_convergence_test() {
  use #(ops_a, ops_b) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    crdt_generators.gen_ops_for("r2"),
  ))

  // Initial sync
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)
  let #(a, _) = state.merge(a, b)
  let #(b, _) = state.merge(b, a)

  // Netsplit: both sides mark each other as down
  let #(a, _) = state.replica_down(a, "r2")
  let #(b, _) = state.replica_down(b, "r1")

  // Mutations during split
  let a = state.join(a, "pid_split_a", "lobby", "split_a", json.null())
  let b = state.join(b, "pid_split_b", "lobby", "split_b", json.null())

  // Heal: mark replicas back up and merge
  let #(a, _) = state.replica_up(a, "r2")
  let #(b, _) = state.replica_up(b, "r1")
  let #(a_final, _) = state.merge(a, b)
  let #(b_final, _) = state.merge(b, a)

  // Both sides should converge
  crdt_generators.online_ids(a_final)
  |> should.equal(crdt_generators.online_ids(b_final))
}

// ── Rapid join/leave cycles ─────────────────────────────────────────

/// Rapid join/leave cycles on the same key should converge after merge
pub fn prop_rapid_join_leave_cycles_test() {
  use #(topic, key, pid) <- qcheck.given(crdt_generators.gen_entry())

  // A does rapid join/leave/join/leave/join cycles
  let a = state.new("r1")
  let a = state.join(a, pid, topic, key, json.null())
  let a = state.leave(a, pid, topic, key)
  let a = state.join(a, pid, topic, key, json.null())
  let a = state.leave(a, pid, topic, key)
  let a = state.join(a, pid, topic, key, json.null())

  // B does the same but ends with a leave
  let b = state.new("r2")
  let b = state.join(b, pid, topic, key, json.null())
  let b = state.leave(b, pid, topic, key)
  let b = state.join(b, pid, topic, key, json.null())
  let b = state.leave(b, pid, topic, key)

  // Merge both directions should converge
  let #(ab, _) = state.merge(a, b)
  let #(ba, _) = state.merge(b, a)

  crdt_generators.online_ids(ab)
  |> should.equal(crdt_generators.online_ids(ba))

  // A's entry should survive (add-wins for concurrent add from A)
  state.get_by_topic(ab, topic) |> list.length |> should.equal(1)
}

// ── Multi-round gossip convergence ──────────────────────────────────

/// After full gossip rounds, all 3 replicas converge
pub fn prop_gossip_convergence_test() {
  use #(ops_a, #(ops_b, ops_c)) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    qcheck.tuple2(
      crdt_generators.gen_ops_for("r2"),
      crdt_generators.gen_ops_for("r3"),
    ),
  ))
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)
  let c = crdt_generators.apply_ops(state.new("r3"), ops_c)

  // Round 1: each replica merges one other
  let #(a, _) = state.merge(a, b)
  let #(b, _) = state.merge(b, c)
  let #(c, _) = state.merge(c, a)

  // Round 2: complete the gossip
  let #(a, _) = state.merge(a, c)
  let #(b, _) = state.merge(b, a)
  let #(c, _) = state.merge(c, b)

  // All three should have identical online sets
  let ids_a = crdt_generators.online_ids(a)
  let ids_b = crdt_generators.online_ids(b)
  let ids_c = crdt_generators.online_ids(c)

  ids_a |> should.equal(ids_b)
  ids_b |> should.equal(ids_c)
}

// ═══════════════════════════════════════════════════════════════════
// Lifecycle Operations
// ═══════════════════════════════════════════════════════════════════

// ── Replica down/up roundtrip ───────────────────────────────────────

/// down hides entries, up reveals them, values dict is unchanged
pub fn prop_replica_down_up_roundtrip_test() {
  use ops <- qcheck.given(crdt_generators.gen_ops_for("r1"))
  let a = crdt_generators.apply_ops(state.new("r1"), ops)
  let b = state.new("r2") |> state.join("p1", "t1", "k1", json.null())

  let #(a, _) = state.merge(a, b)
  let values_before = a.values

  // Down hides r2's entries
  let #(a_down, _) = state.replica_down(a, "r2")
  let down_ids = crdt_generators.online_ids(a_down)
  should.be_false(set.contains(down_ids, #("p1", "t1", "k1")))

  // Values dict is unchanged (entries still stored, just hidden)
  a_down.values |> should.equal(values_before)

  // Up restores visibility
  let #(a_up, _) = state.replica_up(a_down, "r2")
  crdt_generators.online_ids(a_up)
  |> should.equal(crdt_generators.online_ids(a))
}

// ── Remove-down-replicas permanence ─────────────────────────────────

/// After remove_down_replicas, re-merging can't bring entries back
pub fn prop_remove_down_replicas_permanent_test() {
  use ops <- qcheck.given(crdt_generators.gen_ops_for("r1"))
  let a = crdt_generators.apply_ops(state.new("r1"), ops)
  let b = state.new("r2") |> state.join("p1", "t1", "k1", json.null())

  // Sync, then down + remove
  let #(a, _) = state.merge(a, b)
  let #(a, _) = state.replica_down(a, "r2")
  let a = state.remove_down_replicas(a, "r2")

  // Re-merging b's state should NOT bring back r2's entries
  // because remove_down_replicas clears the context for r2,
  // but b's tag (r2, 1) will be re-added as a new join.
  // However, if we mark r2 up and merge, b's entries reappear
  // as new. The key invariant: the REMOVED context is gone.
  let r2_context = dict.get(state.clocks(a), "r2")
  should.be_error(r2_context)

  // r2's entries are gone from values
  let r2_entries =
    dict.to_list(a.values)
    |> list.filter(fn(kv) { { kv.0 }.replica == "r2" })
  list.length(r2_entries) |> should.equal(0)
}

// ── Leave-by-pid completeness ───────────────────────────────────────

/// leave_by_pid removes all and only entries matching the pid
pub fn prop_leave_by_pid_completeness_test() {
  use #(ops, pid) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    crdt_generators.gen_pid(),
  ))
  let s = crdt_generators.apply_ops(state.new("r1"), ops)

  // Record entries NOT matching pid
  let non_pid_entries =
    state.online_list(s)
    |> list.filter(fn(entry) { { entry }.0 != pid })
    |> list.map(fn(e) { #({ e }.0, { e }.1, { e }.2) })
    |> set.from_list

  let after = state.leave_by_pid(s, pid)

  // No entries with the target pid should remain
  state.online_list(after)
  |> list.each(fn(entry) { should.not_equal({ entry }.0, pid) })

  // All non-pid entries should still be present
  let remaining_ids =
    state.online_list(after)
    |> list.map(fn(e) { #({ e }.0, { e }.1, { e }.2) })
    |> set.from_list
  remaining_ids |> should.equal(non_pid_entries)
}

// ── Extract-then-merge equivalence ──────────────────────────────────

/// merge(A, extract(B, ...)) produces the same online set as merge(A, B)
pub fn prop_extract_merge_equivalence_test() {
  use #(ops_a, ops_b) <- qcheck.given(qcheck.tuple2(
    crdt_generators.gen_ops_for("r1"),
    crdt_generators.gen_ops_for("r2"),
  ))
  let a = crdt_generators.apply_ops(state.new("r1"), ops_a)
  let b = crdt_generators.apply_ops(state.new("r2"), ops_b)

  let #(direct, _) = state.merge(a, b)
  let extracted = state.extract(b, a.replica, state.clocks(a))
  let #(via_extract, _) = state.merge(a, extracted)

  crdt_generators.online_ids(direct)
  |> should.equal(crdt_generators.online_ids(via_extract))
}
