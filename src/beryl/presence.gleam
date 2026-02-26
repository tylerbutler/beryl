//// Presence - Distributed presence tracking backed by a CRDT
////
//// Wraps the pure `beryl/presence/state` CRDT in an OTP actor that:
//// - Handles track/untrack calls
//// - Periodically broadcasts state via PubSub for cross-node replication
//// - Receives remote state and merges it
//// - Pushes `"presence_state"` and `"presence_diff"` events to channels
////
//// ## Example
////
//// ```gleam
//// let assert Ok(ps) = pubsub.start(pubsub.default_config())
//// let config = presence.Config(
////   pubsub: ps,
////   replica: "node1",
////   broadcast_interval_ms: 1500,
//// )
//// let assert Ok(p) = presence.start(config)
//// let assert Ok(ref) = presence.track(p, "room:lobby", "user:1", meta)
//// let entries = presence.list(p, "room:lobby")
//// ```

import beryl/presence/state.{type Diff, type State}
import beryl/pubsub.{type PubSub}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

/// A running Presence instance
pub type Presence {
  Presence(subject: Subject(Message))
}

/// Configuration for starting presence
pub type Config {
  Config(
    /// PubSub instance for cross-node replication
    pubsub: Option(PubSub),
    /// This node's replica name (must be unique across the cluster)
    replica: String,
    /// How often to broadcast state for replication (ms). 0 = disabled.
    broadcast_interval_ms: Int,
  )
}

/// A presence entry returned from queries
pub type PresenceEntry {
  PresenceEntry(pid: String, key: String, meta: json.Json)
}

/// Errors from presence operations
pub type PresenceError {
  /// The actor failed to start
  StartFailed
}

/// Messages the presence actor handles
pub opaque type Message {
  Track(
    topic: String,
    key: String,
    pid: String,
    meta: json.Json,
    reply: Subject(String),
  )
  Untrack(topic: String, key: String, pid: String, reply: Subject(Nil))
  UntrackAll(pid: String, reply: Subject(Nil))
  List(topic: String, reply: Subject(List(PresenceEntry)))
  GetByKey(
    topic: String,
    key: String,
    reply: Subject(List(#(String, json.Json))),
  )
  GetDiff(
    topic: String,
    reply: Subject(#(List(PresenceEntry), List(PresenceEntry))),
  )
  MergeRemote(remote: State)
  BroadcastTick
}

/// Internal actor state
type ActorState {
  ActorState(
    crdt: State,
    config: Config,
    /// Track the latest diff from the last merge/mutation for push
    last_diff: Option(Diff),
  )
}

/// Default configuration (no PubSub, no replication)
pub fn default_config(replica: String) -> Config {
  Config(pubsub: None, replica: replica, broadcast_interval_ms: 0)
}

/// Start the presence actor
pub fn start(config: Config) -> Result(Presence, PresenceError) {
  build_presence(config)
  |> actor.start
  |> result.map(fn(started) { Presence(subject: started.data) })
  |> result.map_error(fn(_) { StartFailed })
}

/// Start the presence actor with a registered name (for supervision)
pub fn start_named(
  config: Config,
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  build_presence(config)
  |> actor.named(name)
  |> actor.start
}

fn build_presence(
  config: Config,
) -> actor.Builder(ActorState, Message, Subject(Message)) {
  let crdt = state.new(config.replica)
  let initial = ActorState(crdt: crdt, config: config, last_diff: None)

  actor.new(initial)
  |> actor.on_message(handle_message)
}

/// Track a presence in a topic
///
/// Returns a reference string (the pid) that can be used to untrack later.
pub fn track(
  presence: Presence,
  topic: String,
  key: String,
  pid: String,
  meta: json.Json,
) -> String {
  process.call(presence.subject, 5000, fn(reply) {
    Track(topic, key, pid, meta, reply)
  })
}

/// Untrack a specific presence by topic, key, and pid
pub fn untrack(
  presence: Presence,
  topic: String,
  key: String,
  pid: String,
) -> Nil {
  process.call(presence.subject, 5000, fn(reply) {
    Untrack(topic, key, pid, reply)
  })
}

/// Untrack all presences for a pid (e.g., when a socket disconnects)
pub fn untrack_all(presence: Presence, pid: String) -> Nil {
  process.call(presence.subject, 5000, fn(reply) { UntrackAll(pid, reply) })
}

/// List all presences for a topic
pub fn list(presence: Presence, topic: String) -> List(PresenceEntry) {
  process.call(presence.subject, 5000, fn(reply) { List(topic, reply) })
}

/// Get presences for a specific key within a topic
pub fn get_by_key(
  presence: Presence,
  topic: String,
  key: String,
) -> List(#(String, json.Json)) {
  process.call(presence.subject, 5000, fn(reply) { GetByKey(topic, key, reply) })
}

/// Get the current state as joins/leaves diff for a topic
///
/// Returns `#(joins, leaves)` where each is a list of PresenceEntry.
pub fn get_diff(
  presence: Presence,
  topic: String,
) -> #(List(PresenceEntry), List(PresenceEntry)) {
  process.call(presence.subject, 5000, fn(reply) { GetDiff(topic, reply) })
}

/// Send remote state to merge (fire and forget)
///
/// Used for cross-node replication. The remote state will be merged
/// into the local CRDT, producing a diff of changes.
pub fn merge_remote(presence: Presence, remote: State) -> Nil {
  process.send(presence.subject, MergeRemote(remote))
}

// ── Actor loop ──────────────────────────────────────────────────────────────

fn handle_message(
  actor_state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  case message {
    Track(topic, key, pid, meta, reply) -> {
      let new_crdt = state.join(actor_state.crdt, pid, topic, key, meta)
      process.send(reply, pid)
      actor.continue(ActorState(..actor_state, crdt: new_crdt))
    }

    Untrack(topic, key, pid, reply) -> {
      let new_crdt = state.leave(actor_state.crdt, pid, topic, key)
      process.send(reply, Nil)
      actor.continue(ActorState(..actor_state, crdt: new_crdt))
    }

    UntrackAll(pid, reply) -> {
      let new_crdt = state.leave_by_pid(actor_state.crdt, pid)
      process.send(reply, Nil)
      actor.continue(ActorState(..actor_state, crdt: new_crdt))
    }

    List(topic, reply) -> {
      let entries =
        state.get_by_topic(actor_state.crdt, topic)
        |> list.map(fn(t) { PresenceEntry(pid: t.0, key: t.1, meta: t.2) })
      process.send(reply, entries)
      actor.continue(actor_state)
    }

    GetByKey(topic, key, reply) -> {
      let entries = state.get_by_key(actor_state.crdt, topic, key)
      process.send(reply, entries)
      actor.continue(actor_state)
    }

    GetDiff(topic, reply) -> {
      case actor_state.last_diff {
        None -> {
          // No diff available, return current state as all joins
          let joins =
            state.get_by_topic(actor_state.crdt, topic)
            |> list.map(fn(t) { PresenceEntry(pid: t.0, key: t.1, meta: t.2) })
          process.send(reply, #(joins, []))
          actor.continue(actor_state)
        }
        Some(diff) -> {
          let joins =
            dict.get(diff.joins, topic)
            |> result.unwrap([])
            |> list.map(fn(t) { PresenceEntry(pid: t.0, key: t.1, meta: t.2) })
          let leaves =
            dict.get(diff.leaves, topic)
            |> result.unwrap([])
            |> list.map(fn(t) { PresenceEntry(pid: t.0, key: t.1, meta: t.2) })
          process.send(reply, #(joins, leaves))
          actor.continue(actor_state)
        }
      }
    }

    MergeRemote(remote) -> {
      let #(new_crdt, diff) = state.merge(actor_state.crdt, remote)
      actor.continue(
        ActorState(..actor_state, crdt: new_crdt, last_diff: Some(diff)),
      )
    }

    BroadcastTick -> {
      // Broadcast current state via PubSub for replication
      case actor_state.config.pubsub {
        None -> actor.continue(actor_state)
        Some(_ps) -> {
          // TODO: Serialize CRDT state and broadcast via PubSub
          // This requires a serialization format for the State type.
          // For now, this is a placeholder for future delta replication.
          actor.continue(actor_state)
        }
      }
    }
  }
}
