//// Presence State - compatibility facade over lattice_presence
////
//// Beryl keeps this module so callers using `beryl/presence/state` do not need
//// to immediately switch imports when the CRDT implementation moves to the
//// `lattice_presence` package.

import gleam/dict.{type Dict}
import gleam/json
import lattice_presence/presence_state as lattice

/// Unique identifier for a node in the cluster
pub type Replica =
  lattice.Replica

/// Monotonically increasing counter per replica
pub type Clock =
  lattice.Clock

/// A tag uniquely identifies when and where an entry was created
pub type Tag =
  lattice.Tag

/// A tracked presence entry
pub type Entry =
  lattice.Entry

/// Replica status
pub type ReplicaStatus {
  Up
  Down
}

/// The CRDT state
pub type State =
  lattice.State

/// A diff representing changes between two states
pub type Diff {
  Diff(
    joins: Dict(String, List(#(String, String, json.Json))),
    leaves: Dict(String, List(#(String, String, json.Json))),
  )
}

/// Create a new empty state for this replica
pub fn new(replica: Replica) -> State {
  lattice.new(replica)
}

/// Add a tracked presence. Increments the local clock.
pub fn join(
  state: State,
  pid: String,
  topic: String,
  key: String,
  meta: json.Json,
) -> State {
  lattice.join(state, pid, topic, key, meta)
}

/// Remove a specific presence by pid, topic, and key
pub fn leave(state: State, pid: String, topic: String, key: String) -> State {
  lattice.leave(state, pid, topic, key)
}

/// Remove all presences for a pid
pub fn leave_by_pid(state: State, pid: String) -> State {
  lattice.leave_by_pid(state, pid)
}

/// List all online presences across all topics (from non-down replicas)
pub fn online_list(state: State) -> List(#(String, String, String, json.Json)) {
  lattice.online_list(state)
}

/// Get all presences for a topic (from non-down replicas)
pub fn get_by_topic(
  state: State,
  topic: String,
) -> List(#(String, String, json.Json)) {
  lattice.get_by_topic(state, topic)
}

/// Get presences for a specific key within a topic
pub fn get_by_key(
  state: State,
  topic: String,
  key: String,
) -> List(#(String, json.Json)) {
  lattice.get_by_key(state, topic, key)
}

/// Merge remote state into local state and return the diff.
pub fn merge(local: State, remote: State) -> #(State, Diff) {
  let #(merged, diff) = lattice.merge_with_diff(local, remote)
  #(merged, from_lattice_diff(diff))
}

/// Merge remote state into local state and return the diff.
pub fn merge_with_diff(local: State, remote: State) -> #(State, Diff) {
  merge(local, remote)
}

/// Compact clouds into context where possible.
pub fn compact(state: State) -> State {
  lattice.compact(state)
}

/// Extract state for sending to a remote replica.
pub fn extract(
  state: State,
  _remote_replica: Replica,
  _remote_context: Dict(Replica, Clock),
) -> State {
  lattice.extract_full_state(state)
}

/// Extract the full state for sending to a remote replica.
pub fn extract_full_state(state: State) -> State {
  lattice.extract_full_state(state)
}

/// Get the current compacted vector clock.
pub fn clocks(state: State) -> Dict(Replica, Clock) {
  lattice.compacted_clocks(state)
}

/// Get the current compacted vector clock.
pub fn compacted_clocks(state: State) -> Dict(Replica, Clock) {
  lattice.compacted_clocks(state)
}

/// Get this state's replica name.
pub fn replica(state: State) -> Replica {
  lattice.replica(state)
}

/// Return the number of entries retained by the CRDT state.
pub fn entry_count(state: State) -> Int {
  lattice.entry_count(state)
}

/// Return the number of uncompacted cloud entries retained by the state.
pub fn cloud_count(state: State) -> Int {
  lattice.cloud_count(state)
}

/// Mark a replica as down. Returns entries that are now invisible (leaves).
pub fn replica_down(state: State, replica: Replica) -> #(State, Diff) {
  let #(new_state, diff) = lattice.replica_down(state, replica)
  #(new_state, from_lattice_diff(diff))
}

/// Mark a replica as up. Returns entries that are now visible again (joins).
pub fn replica_up(state: State, replica: Replica) -> #(State, Diff) {
  let #(new_state, diff) = lattice.replica_up(state, replica)
  #(new_state, from_lattice_diff(diff))
}

/// Permanently remove all entries and context for a downed replica.
pub fn remove_down_replicas(state: State, replica: Replica) -> State {
  lattice.remove_down_replica(state, replica)
}

/// Permanently remove all entries and context for a downed replica.
pub fn remove_down_replica(state: State, replica: Replica) -> State {
  lattice.remove_down_replica(state, replica)
}

fn from_lattice_diff(diff: lattice.Diff) -> Diff {
  let lattice.Diff(joins: joins, leaves: leaves) = diff
  Diff(joins: joins, leaves: leaves)
}
