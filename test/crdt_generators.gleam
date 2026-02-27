/// Custom generators for property-based testing of the CRDT presence state.
///
/// Uses small pools so that operations frequently collide on the same
/// pid/topic/key across replicas — this is where CRDT bugs hide.
import beryl/presence/state.{type State}
import gleam/dict
import gleam/json
import gleam/list
import gleam/set
import qcheck

// ── Operation type ──────────────────────────────────────────────────

pub type Op {
  Join(replica: String, pid: String, topic: String, key: String)
  Leave(replica: String, pid: String, topic: String, key: String)
}

// ── Element generators ──────────────────────────────────────────────

fn gen_from_list(items: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = items
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

pub fn gen_replica() -> qcheck.Generator(String) {
  gen_from_list(["r1", "r2", "r3"])
}

pub fn gen_pid() -> qcheck.Generator(String) {
  gen_from_list(["pid1", "pid2", "pid3", "pid4"])
}

pub fn gen_topic() -> qcheck.Generator(String) {
  gen_from_list(["lobby", "room:1", "room:2"])
}

pub fn gen_key() -> qcheck.Generator(String) {
  gen_from_list(["alice", "bob", "carol", "dave"])
}

// ── Operation generators ────────────────────────────────────────────

/// Generate a single CRDT operation for a specific replica
pub fn gen_op_for(replica: String) -> qcheck.Generator(Op) {
  let gen_join =
    qcheck.map3(gen_pid(), gen_topic(), gen_key(), fn(pid, topic, key) {
      Join(replica: replica, pid: pid, topic: topic, key: key)
    })
  let gen_leave =
    qcheck.map3(gen_pid(), gen_topic(), gen_key(), fn(pid, topic, key) {
      Leave(replica: replica, pid: pid, topic: topic, key: key)
    })
  // Bias towards joins (70/30) so states aren't mostly empty
  qcheck.from_weighted_generators(#(7, gen_join), [#(3, gen_leave)])
}

/// Generate a list of operations for a specific replica
pub fn gen_ops_for(replica: String) -> qcheck.Generator(List(Op)) {
  qcheck.list_from(gen_op_for(replica))
}

/// Generate an entry tuple (topic, key, pid) for add-wins tests
pub fn gen_entry() -> qcheck.Generator(#(String, String, String)) {
  qcheck.tuple3(gen_topic(), gen_key(), gen_pid())
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Apply a list of operations to a state, ignoring the replica field on ops
/// (the state's own replica is used for joins)
pub fn apply_ops(s: State, ops: List(Op)) -> State {
  list.fold(ops, s, fn(acc, op) {
    case op {
      Join(_, pid, topic, key) -> state.join(acc, pid, topic, key, json.null())
      Leave(_, pid, topic, key) -> state.leave(acc, pid, topic, key)
    }
  })
}

/// Get the identity tuples (pid, topic, key) from online_list, as a set
pub fn online_ids(s: State) -> set.Set(#(String, String, String)) {
  state.online_list(s)
  |> list.map(fn(entry) {
    let #(pid, topic, key, _) = entry
    #(pid, topic, key)
  })
  |> set.from_list
}

/// Compare two states by their online identity sets
pub fn same_online(a: State, b: State) -> Bool {
  online_ids(a) == online_ids(b)
}

/// Extract identity tuples from a diff's topic-grouped entries
pub fn diff_entry_ids(
  topic_entries: dict.Dict(String, List(#(String, String, json.Json))),
) -> set.Set(#(String, String, String)) {
  dict.to_list(topic_entries)
  |> list.flat_map(fn(kv) {
    let #(topic, entries) = kv
    list.map(entries, fn(e) {
      let #(key, pid, _meta) = e
      #(pid, topic, key)
    })
  })
  |> set.from_list
}
