//// Presence State - Pure CRDT for distributed presence tracking
////
//// A causal-context add-wins observed-remove set, inspired by Phoenix.Tracker.State.
//// This module is a pure data structure with no actors or side effects.
////
//// Each node (replica) tracks its own presences authoritatively. State is
//// replicated by extracting deltas and merging them at remote replicas.
//// Conflicts are resolved causally: adds win over concurrent removes.

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/set.{type Set}

/// Unique identifier for a node in the cluster
pub type Replica =
  String

/// Monotonically increasing counter per replica
pub type Clock =
  Int

/// A tag uniquely identifies when and where an entry was created
pub type Tag {
  Tag(replica: Replica, clock: Clock)
}

/// A tracked presence entry
pub type Entry {
  Entry(
    topic: String,
    key: String,
    /// Unique identifier for the tracked entity (e.g., socket ID, user ID)
    pid: String,
    /// Arbitrary metadata
    meta: json.Json,
  )
}

/// Replica status
pub type ReplicaStatus {
  Up
  Down
}

/// The CRDT state
pub type State {
  State(
    /// This node's replica name
    replica: Replica,
    /// Vector clock: replica -> latest compacted clock value
    context: Dict(Replica, Clock),
    /// Per-replica sets of observed-but-not-compacted clock values
    clouds: Dict(Replica, Set(Clock)),
    /// Tag -> Entry: all tracked presences
    values: Dict(Tag, Entry),
    /// Replica status tracking
    replicas: Dict(Replica, ReplicaStatus),
  )
}

/// A diff representing changes between two states
pub type Diff {
  Diff(
    joins: Dict(String, List(#(String, String, json.Json))),
    leaves: Dict(String, List(#(String, String, json.Json))),
  )
}

// ── Core operations ─────────────────────────────────────────────────

/// Create a new empty state for this replica
pub fn new(replica: Replica) -> State {
  State(
    replica: replica,
    context: dict.new(),
    clouds: dict.new(),
    values: dict.new(),
    replicas: dict.from_list([#(replica, Up)]),
  )
}

/// Add a tracked presence. Increments the local clock.
pub fn join(
  state: State,
  pid: String,
  topic: String,
  key: String,
  meta: json.Json,
) -> State {
  let clock = next_clock(state, state.replica)
  let tag = Tag(replica: state.replica, clock: clock)
  let entry = Entry(topic: topic, key: key, pid: pid, meta: meta)
  let new_context = dict.insert(state.context, state.replica, clock)
  let new_values = dict.insert(state.values, tag, entry)
  State(..state, context: new_context, values: new_values)
}

/// Remove a specific presence by pid, topic, and key
pub fn leave(state: State, pid: String, topic: String, key: String) -> State {
  let new_values =
    dict.filter(state.values, fn(_, entry) {
      case entry.pid == pid && entry.topic == topic && entry.key == key {
        True -> False
        False -> True
      }
    })
  State(..state, values: new_values)
}

/// Remove all presences for a pid
pub fn leave_by_pid(state: State, pid: String) -> State {
  let new_values = dict.filter(state.values, fn(_, entry) { entry.pid != pid })
  State(..state, values: new_values)
}

// ── Query operations ────────────────────────────────────────────────

/// List all online presences across all topics (from non-down replicas)
pub fn online_list(state: State) -> List(#(String, String, String, json.Json)) {
  state.values
  |> dict.to_list()
  |> list.filter(fn(kv) {
    let #(tag, _) = kv
    is_replica_up(state, tag.replica)
  })
  |> list.map(fn(kv) {
    let #(_, entry) = kv
    #(entry.pid, entry.topic, entry.key, entry.meta)
  })
}

/// Get all presences for a topic (from non-down replicas)
pub fn get_by_topic(
  state: State,
  topic: String,
) -> List(#(String, String, json.Json)) {
  state.values
  |> dict.to_list()
  |> list.filter(fn(kv) {
    let #(tag, entry) = kv
    entry.topic == topic && is_replica_up(state, tag.replica)
  })
  |> list.map(fn(kv) {
    let #(_, entry) = kv
    #(entry.pid, entry.key, entry.meta)
  })
}

/// Get presences for a specific key within a topic
pub fn get_by_key(
  state: State,
  topic: String,
  key: String,
) -> List(#(String, json.Json)) {
  state.values
  |> dict.to_list()
  |> list.filter(fn(kv) {
    let #(tag, entry) = kv
    entry.topic == topic
    && entry.key == key
    && is_replica_up(state, tag.replica)
  })
  |> list.map(fn(kv) {
    let #(_, entry) = kv
    #(entry.pid, entry.meta)
  })
}

// ── Merge ───────────────────────────────────────────────────────────

/// Merge remote state into local state.
/// Returns the new merged state and a diff of what changed.
pub fn merge(local: State, remote: State) -> #(State, Diff) {
  // 1. Find new entries from remote (tags we haven't seen)
  let joins =
    dict.to_list(remote.values)
    |> list.filter(fn(kv) {
      let #(tag, _) = kv
      case tag_is_in(local.context, local.clouds, tag) {
        True -> False
        False -> True
      }
    })

  // 2. Find entries we should remove (in remote's causal context but not in remote's values)
  let removes =
    dict.to_list(local.values)
    |> list.filter(fn(kv) {
      let #(tag, _) = kv
      tag.replica != local.replica
      && tag_is_in(remote.context, remote.clouds, tag)
      && {
        case dict.has_key(remote.values, tag) {
          True -> False
          False -> True
        }
      }
    })

  // 3. Apply changes
  let new_values =
    list.fold(removes, local.values, fn(vals, kv) {
      let #(tag, _) = kv
      dict.delete(vals, tag)
    })
  let new_values =
    list.fold(joins, new_values, fn(vals, kv) {
      let #(tag, entry) = kv
      dict.insert(vals, tag, entry)
    })

  // 4. Advance context: take max of local and remote for each replica
  let new_context = merge_contexts(local.context, remote.context)

  // 5. Merge clouds
  let new_clouds = merge_clouds(local.clouds, remote.clouds)

  // 6. Build diff
  let join_diff = entries_to_topic_diff(list.map(joins, fn(kv) { kv.1 }))
  let leave_diff = entries_to_topic_diff(list.map(removes, fn(kv) { kv.1 }))
  let diff = Diff(joins: join_diff, leaves: leave_diff)

  let new_state =
    State(..local, context: new_context, clouds: new_clouds, values: new_values)

  #(compact(new_state), diff)
}

/// Check if a tag is "in" a causal context (either compacted or in clouds)
fn tag_is_in(
  context: Dict(Replica, Clock),
  clouds: Dict(Replica, Set(Clock)),
  tag: Tag,
) -> Bool {
  case dict.get(context, tag.replica) {
    Ok(clock) if clock >= tag.clock -> True
    _ -> {
      case dict.get(clouds, tag.replica) {
        Ok(cloud) -> set.contains(cloud, tag.clock)
        Error(_) -> False
      }
    }
  }
}

/// Merge two vector clocks (take max per replica)
fn merge_contexts(
  a: Dict(Replica, Clock),
  b: Dict(Replica, Clock),
) -> Dict(Replica, Clock) {
  dict.combine(a, b, fn(ca, cb) {
    case ca > cb {
      True -> ca
      False -> cb
    }
  })
}

/// Merge cloud sets
fn merge_clouds(
  a: Dict(Replica, Set(Clock)),
  b: Dict(Replica, Set(Clock)),
) -> Dict(Replica, Set(Clock)) {
  dict.combine(a, b, fn(sa, sb) { set.union(sa, sb) })
}

/// Compact clouds into context where possible
///
/// If context[replica] + 1 is in the cloud, advance context and remove from cloud.
/// Repeat until no more compaction possible.
pub fn compact(state: State) -> State {
  let #(new_context, new_clouds) =
    dict.fold(
      state.clouds,
      #(state.context, state.clouds),
      fn(acc, replica, cloud) {
        let #(ctx, clouds) = acc
        let base = case dict.get(ctx, replica) {
          Ok(c) -> c
          Error(_) -> 0
        }
        let #(new_base, remaining) = compact_cloud(base, cloud)
        let new_ctx = case new_base > base {
          True -> dict.insert(ctx, replica, new_base)
          False -> ctx
        }
        let new_clouds = case set.size(remaining) {
          0 -> dict.delete(clouds, replica)
          _ -> dict.insert(clouds, replica, remaining)
        }
        #(new_ctx, new_clouds)
      },
    )

  State(..state, context: new_context, clouds: new_clouds)
}

/// Compact a single cloud: advance base clock through contiguous values
fn compact_cloud(base: Clock, cloud: Set(Clock)) -> #(Clock, Set(Clock)) {
  case set.contains(cloud, base + 1) {
    True -> compact_cloud(base + 1, set.delete(cloud, base + 1))
    False -> #(base, cloud)
  }
}

/// Group entries by topic for diff reporting
fn entries_to_topic_diff(
  entries: List(Entry),
) -> Dict(String, List(#(String, String, json.Json))) {
  list.fold(entries, dict.new(), fn(acc, entry) {
    let existing = case dict.get(acc, entry.topic) {
      Ok(l) -> l
      Error(_) -> []
    }
    dict.insert(acc, entry.topic, [
      #(entry.key, entry.pid, entry.meta),
      ..existing
    ])
  })
}

// ── Extract (delta) ─────────────────────────────────────────────────

/// Extract state for sending to a remote replica.
///
/// Returns the full local state. The remote's merge handles
/// deduplication of entries it already has. Absence of an entry
/// combined with coverage in context = observed removal.
///
/// Note: Phoenix's extract filters to "known replicas" and requires
/// replica_up() before sync. Our design allows direct merge without
/// replica_up, so we send the full state. Delta optimization
/// (sending only new entries) requires proper delta tracking and
/// will be added in a future iteration.
pub fn extract(
  state: State,
  _remote_replica: Replica,
  _remote_context: Dict(Replica, Clock),
) -> State {
  state
}

// ── Introspection ───────────────────────────────────────────────────

/// Get the current vector clock
pub fn clocks(state: State) -> Dict(Replica, Clock) {
  state.context
}

// ── Replica lifecycle ────────────────────────────────────────────────

/// Mark a replica as down. Returns entries that are now invisible (leaves).
pub fn replica_down(state: State, replica: Replica) -> #(State, Diff) {
  let new_replicas = dict.insert(state.replicas, replica, Down)
  let new_state = State(..state, replicas: new_replicas)

  // Compute what just "left" — all entries from this replica
  let hidden =
    dict.to_list(state.values)
    |> list.filter(fn(kv) { { kv.0 }.replica == replica })
    |> list.map(fn(kv) { kv.1 })

  let diff = Diff(joins: dict.new(), leaves: entries_to_topic_diff(hidden))
  #(new_state, diff)
}

/// Mark a replica as up. Returns entries that are now visible again (joins).
pub fn replica_up(state: State, replica: Replica) -> #(State, Diff) {
  let new_replicas = dict.insert(state.replicas, replica, Up)
  let new_state = State(..state, replicas: new_replicas)

  // Compute what just "joined" — all entries from this replica
  let restored =
    dict.to_list(state.values)
    |> list.filter(fn(kv) { { kv.0 }.replica == replica })
    |> list.map(fn(kv) { kv.1 })

  let diff = Diff(joins: entries_to_topic_diff(restored), leaves: dict.new())
  #(new_state, diff)
}

/// Permanently remove all entries and context for a downed replica
pub fn remove_down_replicas(state: State, replica: Replica) -> State {
  let new_values =
    dict.filter(state.values, fn(tag, _) { tag.replica != replica })
  let new_context = dict.delete(state.context, replica)
  let new_clouds = dict.delete(state.clouds, replica)
  let new_replicas = dict.delete(state.replicas, replica)
  State(
    ..state,
    values: new_values,
    context: new_context,
    clouds: new_clouds,
    replicas: new_replicas,
  )
}

// ── Internal helpers ────────────────────────────────────────────────

fn next_clock(state: State, replica: Replica) -> Clock {
  case dict.get(state.context, replica) {
    Ok(c) -> c + 1
    Error(_) -> 1
  }
}

fn is_replica_up(state: State, replica: Replica) -> Bool {
  case dict.get(state.replicas, replica) {
    Ok(Up) -> True
    Ok(Down) -> False
    // Unknown replicas assumed up (first contact)
    Error(_) -> True
  }
}
