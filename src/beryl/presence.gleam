//// Presence - Distributed presence tracking backed by a CRDT
////
//// Wraps the pure `beryl/presence/state` CRDT in an OTP actor that:
//// - Handles track/untrack calls
//// - Periodically broadcasts state via PubSub for cross-node replication
//// - Receives remote state and merges it
//// - Invokes `on_diff` callback when merges produce non-empty diffs
////
//// ## Example
////
//// ```gleam
//// let assert Ok(ps) = pubsub.start(pubsub.default_config())
//// let config = presence.Config(
////   pubsub: ps,
////   replica: "node1",
////   broadcast_interval_ms: 1500,
////   on_diff: None,
//// )
//// let assert Ok(p) = presence.start(config)
//// let assert Ok(ref) = presence.track(p, "room:lobby", "user:1", meta)
//// let entries = presence.list(p, "room:lobby")
//// ```

import beryl/internal
import beryl/presence/state.{type Diff, type State}
import beryl/presence/state_json
import beryl/pubsub.{type PubSub}
import birch/logger as log
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode as gdecode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

/// Well-known PubSub topic for presence state replication
const sync_topic = "beryl:presence:sync"

/// PubSub event name for presence sync messages
const sync_event = "presence_sync"

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
    /// Optional callback invoked immediately when a merge produces a non-empty diff.
    /// This ensures no diffs are lost when multiple merges occur in rapid succession.
    on_diff: Option(fn(Diff) -> Nil),
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
  MergeRemote(remote: State)
  BroadcastTick
  /// Incoming PubSub sync message from a remote replica
  RemoteSync(pubsub_msg: pubsub.Message)
}

/// Internal actor state
type ActorState {
  ActorState(
    crdt: State,
    config: Config,
    /// The actor's own subject, needed for scheduling BroadcastTick
    self_subject: Option(Subject(Message)),
  )
}

/// Default configuration (no PubSub, no replication)
pub fn default_config(replica: String) -> Config {
  Config(
    pubsub: None,
    replica: replica,
    broadcast_interval_ms: 0,
    on_diff: None,
  )
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

  actor.new_with_initialiser(5000, fn(subject) {
    let initial =
      ActorState(crdt: crdt, config: config, self_subject: Some(subject))

    case config.pubsub {
      Some(ps) -> {
        // Subscribe to the well-known sync topic for replication
        pubsub.subscribe(ps, sync_topic)
        let logger = internal.logger("beryl.presence")
        logger
        |> log.debug("Subscribed to PubSub sync topic", [
          #("topic", sync_topic),
          #("replica", config.replica),
        ])

        // Build selector: handle actor subject messages + PubSub record messages
        // PubSub.Message on BEAM is {message, Topic, Event, Payload, From}
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> process.select_record(
            atom.create("message"),
            4,
            fn(raw: Dynamic) -> Message {
              RemoteSync(coerce_to_pubsub_message(raw))
            },
          )

        // Schedule the first broadcast tick if enabled
        schedule_broadcast_tick(subject, config.broadcast_interval_ms)

        actor.initialised(initial)
        |> actor.selecting(selector)
        |> actor.returning(subject)
        |> Ok
      }
      None -> {
        let no_pubsub_initial =
          ActorState(crdt: crdt, config: config, self_subject: None)
        actor.initialised(no_pubsub_initial)
        |> actor.returning(subject)
        |> Ok
      }
    }
  })
  |> actor.on_message(handle_message)
}

/// Schedule the next broadcast tick if the interval is positive
fn schedule_broadcast_tick(subject: Subject(Message), interval_ms: Int) -> Nil {
  case interval_ms > 0 {
    True -> {
      let _ = process.send_after(subject, interval_ms, BroadcastTick)
      Nil
    }
    False -> Nil
  }
}

/// Coerce a Dynamic value to pubsub.Message.
/// Safe because we match on the `message` record tag via select_record.
@external(erlang, "beryl_ffi", "identity")
fn coerce_to_pubsub_message(value: Dynamic) -> pubsub.Message

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
  let logger = internal.logger("beryl.presence")
  case message {
    Track(topic, key, pid, meta, reply) -> {
      let new_crdt = state.join(actor_state.crdt, pid, topic, key, meta)
      logger
      |> log.debug("Presence tracked", [
        #("topic", topic),
        #("key", key),
        #("pid", pid),
      ])
      process.send(reply, pid)
      actor.continue(ActorState(..actor_state, crdt: new_crdt))
    }

    Untrack(topic, key, pid, reply) -> {
      let new_crdt = state.leave(actor_state.crdt, pid, topic, key)
      logger
      |> log.debug("Presence untracked", [
        #("topic", topic),
        #("key", key),
        #("pid", pid),
      ])
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

    MergeRemote(remote) -> {
      let #(new_crdt, diff) = state.merge(actor_state.crdt, remote)
      maybe_invoke_on_diff(actor_state.config, diff)
      actor.continue(ActorState(..actor_state, crdt: new_crdt))
    }

    BroadcastTick -> {
      case actor_state.config.pubsub, actor_state.self_subject {
        Some(ps), Some(subject) -> {
          // Build envelope with state as nested JSON object (not double-encoded string)
          let payload =
            json.object([
              #("v", json.int(1)),
              #("sender", json.string(actor_state.config.replica)),
              #("state", state_json.encode(actor_state.crdt)),
            ])

          // Broadcast via PubSub, skipping self-delivery
          pubsub.broadcast_from(
            ps,
            process.self(),
            sync_topic,
            sync_event,
            payload,
          )

          // Reschedule next tick
          schedule_broadcast_tick(
            subject,
            actor_state.config.broadcast_interval_ms,
          )

          actor.continue(actor_state)
        }
        _, _ -> actor.continue(actor_state)
      }
    }

    RemoteSync(pubsub_msg) -> {
      // Only process presence sync messages on the expected topic/event
      case pubsub_msg.topic == sync_topic && pubsub_msg.event == sync_event {
        False -> actor.continue(actor_state)
        True -> {
          let payload_str = json.to_string(pubsub_msg.payload)
          handle_sync_payload(actor_state, payload_str)
        }
      }
    }
  }
}

/// Invoke the on_diff callback if configured and the diff is non-empty
fn maybe_invoke_on_diff(config: Config, diff: Diff) -> Nil {
  case config.on_diff {
    None -> Nil
    Some(callback) -> {
      case dict.is_empty(diff.joins) && dict.is_empty(diff.leaves) {
        True -> Nil
        False -> callback(diff)
      }
    }
  }
}

/// Parse the sync envelope and merge the remote state.
/// Self-delivery is already prevented by broadcast_from at the PubSub layer.
fn handle_sync_payload(
  actor_state: ActorState,
  payload_str: String,
) -> actor.Next(ActorState, Message) {
  case parse_sync_envelope(payload_str) {
    Error(reason) -> {
      let logger = internal.logger("beryl.presence")
      logger
      |> log.warn("Failed to decode presence sync message", [
        #("reason", reason),
        #("payload_length", int.to_string(string.length(payload_str))),
      ])
      actor.continue(actor_state)
    }
    Ok(#(_sender, remote_state)) -> {
      let #(new_crdt, diff) = state.merge(actor_state.crdt, remote_state)
      maybe_invoke_on_diff(actor_state.config, diff)
      actor.continue(ActorState(..actor_state, crdt: new_crdt))
    }
  }
}

/// Parse the sync envelope JSON: {"v": 1, "sender": "...", "state": {...}}
/// State is decoded directly as a nested object (not double-encoded string).
/// Rejects envelopes with unknown version numbers.
@internal
pub fn parse_sync_envelope(
  payload_str: String,
) -> Result(#(String, State), String) {
  let version_decoder = {
    use v <- gdecode.field("v", gdecode.int)
    gdecode.success(v)
  }
  case json.parse(payload_str, version_decoder) {
    Error(_) -> Error("JSON parse or field extraction failed")
    Ok(v) ->
      case v {
        1 -> {
          let decoder = {
            use _v <- gdecode.field("v", gdecode.int)
            use sender <- gdecode.field("sender", gdecode.string)
            use remote_state <- gdecode.field(
              "state",
              state_json.state_decoder(),
            )
            gdecode.success(#(sender, remote_state))
          }
          case json.parse(payload_str, decoder) {
            Ok(result) -> Ok(result)
            Error(_) -> Error("State decode failed")
          }
        }
        _ -> Error("Unknown envelope version: " <> int.to_string(v))
      }
  }
}
