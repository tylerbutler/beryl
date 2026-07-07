//// Presence - Distributed presence tracking backed by a CRDT
////
//// Wraps the pure `lattice_presence/presence_state` CRDT in an OTP actor that:
//// - Handles track/untrack calls
//// - Periodically broadcasts state via PubSub for cross-node replication
//// - Receives remote state from PubSub and merges it internally
//// - Invokes `on_diff` callback when merges produce non-empty diffs
////
//// ## Example
////
//// ```gleam
//// let ps = pubsub.start(pubsub.default_config())
//// let config =
////   presence.default_config("node1")
////   |> presence.with_pubsub(ps)
////   |> presence.with_broadcast_interval(1500)
//// let assert Ok(p) = presence.start(config)
//// let ref = presence.track(p, "room:lobby", "user:1", "socket-1", meta)
//// let entries = presence.list(p, "room:lobby")
//// ```

import beryl/error as beryl_error
import beryl/internal
import beryl/log
import beryl/pubsub.{type PubSub}
import gleam/bool
import gleam/dict.{type Dict}
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
import lattice_presence/presence_state as state
import lattice_presence/state_json

/// Well-known PubSub topic for presence state replication
const sync_topic = "beryl:presence:sync"

/// PubSub event name for presence sync messages
const sync_event = "presence_sync"

/// A running Presence instance.
///
/// This handle is intentionally opaque so callers cannot forge actor subjects
/// or depend on the runtime representation.
pub opaque type Presence {
  Presence(subject: Subject(Message))
}

type State =
  state.State

/// An opaque diff representing presence joins and leaves grouped by topic.
///
/// This is passed to `Config.on_diff` and accepted by
/// `beryl.broadcast_presence_diff`.
pub opaque type Diff {
  Diff(
    joins: Dict(String, List(PresenceEntry)),
    leaves: Dict(String, List(PresenceEntry)),
  )
}

/// A presence entry returned from queries and diff accessors.
///
/// This type is intentionally transparent so callers can inspect query results
/// and construct entries for `diff`.
pub type PresenceEntry {
  PresenceEntry(session_id: String, key: String, meta: json.Json)
}

/// Build a presence diff from topic-grouped joins and leaves.
///
/// Most applications receive diffs from `Config.on_diff`; this helper is for
/// callers that need to construct a diff to pass to `beryl.broadcast_presence_diff`.
pub fn diff(
  joins joins: List(#(String, List(PresenceEntry))),
  leaves leaves: List(#(String, List(PresenceEntry))),
) -> Diff {
  Diff(joins: dict.from_list(joins), leaves: dict.from_list(leaves))
}

/// List topics touched by this diff.
pub fn diff_topics(diff: Diff) -> List(String) {
  list.append(dict.keys(diff.joins), dict.keys(diff.leaves))
  |> unique_strings([])
}

/// Get presence joins for a topic in this diff.
pub fn diff_joins(diff: Diff, topic: String) -> List(PresenceEntry) {
  dict.get(diff.joins, topic)
  |> result.unwrap([])
}

/// Get presence leaves for a topic in this diff.
pub fn diff_leaves(diff: Diff, topic: String) -> List(PresenceEntry) {
  dict.get(diff.leaves, topic)
  |> result.unwrap([])
}

fn unique_strings(values: List(String), seen: List(String)) -> List(String) {
  case values {
    [] -> list.reverse(seen)
    [value, ..rest] ->
      case list.contains(seen, value) {
        True -> unique_strings(rest, seen)
        False -> unique_strings(rest, [value, ..seen])
      }
  }
}

fn wrap_state_diff(diff: state.Diff) -> Diff {
  Diff(
    joins: state_entries_to_presence_entries(diff.joins),
    leaves: state_entries_to_presence_entries(diff.leaves),
  )
}

fn state_entries_to_presence_entries(
  entries: Dict(String, List(#(String, String, json.Json))),
) -> Dict(String, List(PresenceEntry)) {
  entries
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(topic, topic_entries) = entry
    #(
      topic,
      list.map(topic_entries, fn(topic_entry) {
        let #(key, pid, meta) = topic_entry
        PresenceEntry(session_id: pid, key: key, meta: meta)
      }),
    )
  })
  |> dict.from_list
}

/// Configuration for starting presence.
///
/// Build configs with `default_config` and the `with_*` functions so Beryl can
/// add future options without exposing record fields as public API.
pub opaque type Config {
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

/// Errors from presence operations
pub type PresenceError {
  /// The presence actor failed to start.
  PresenceStartFailed(beryl_error.StartFailure)
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
    /// Set whenever the local CRDT mutates; cleared after a broadcast tick.
    /// Skips the encode+broadcast when there is nothing new to gossip.
    dirty: Bool,
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

/// Enable PubSub replication for presence.
pub fn with_pubsub(config: Config, pubsub: PubSub) -> Config {
  Config(..config, pubsub: Some(pubsub))
}

/// Set how often presence state is broadcast for replication.
///
/// Use `0` to disable periodic broadcasts.
pub fn with_broadcast_interval(config: Config, interval_ms: Int) -> Config {
  Config(..config, broadcast_interval_ms: interval_ms)
}

/// Set the callback invoked when local changes or remote merges produce a diff.
pub fn with_on_diff(config: Config, callback: fn(Diff) -> Nil) -> Config {
  Config(..config, on_diff: Some(callback))
}

// nolint: unused_exports -- package-internal constructor for supervised presence; hidden from public docs with @internal
@internal
pub fn from_subject(subject: Subject(Message)) -> Presence {
  Presence(subject: subject)
}

// nolint: unused_exports -- package-internal accessor for supervision tests; hidden from public docs with @internal
@internal
pub fn subject(presence: Presence) -> Subject(Message) {
  presence.subject
}

/// Start the presence actor
pub fn start(config: Config) -> Result(Presence, PresenceError) {
  build_presence(config)
  |> actor.start
  |> result.map(fn(started) { Presence(subject: started.data) })
  |> result.map_error(fn(error) {
    PresenceStartFailed(beryl_error.from_actor_start_error(error))
  })
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
      ActorState(
        crdt: crdt,
        config: config,
        self_subject: Some(subject),
        dirty: False,
      )

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
          ActorState(
            crdt: crdt,
            config: config,
            self_subject: None,
            dirty: False,
          )
        actor.initialised(no_pubsub_initial)
        |> actor.returning(subject)
        |> Ok
      }
    }
  })
  |> actor.on_message(handle_message)
}

/// Broadcast the current CRDT state over PubSub when dirty, returning the
/// updated actor state. Extracted from the `BroadcastTick` handler to keep
/// that branch from nesting too deeply.
fn maybe_broadcast_state(actor_state: ActorState, ps: PubSub) -> ActorState {
  use <- bool.guard(when: !actor_state.dirty, return: actor_state)
  let payload =
    json.object([
      #("v", json.int(1)),
      #("sender", json.string(actor_state.config.replica)),
      #("state", state_json.to_json(actor_state.crdt)),
    ])

  pubsub.broadcast_from(ps, process.self(), sync_topic, sync_event, payload)

  ActorState(..actor_state, dirty: False)
}

/// Schedule the next broadcast tick if the interval is positive
fn schedule_broadcast_tick(subject: Subject(Message), interval_ms: Int) -> Nil {
  use <- bool.guard(when: interval_ms <= 0, return: Nil)
  let _timer = process.send_after(subject, interval_ms, BroadcastTick)
  Nil
}

/// Coerce a Dynamic value to pubsub.Message.
/// Safe because we match on the `message` record tag via select_record.
@external(erlang, "beryl_ffi", "identity")
fn coerce_to_pubsub_message(value: Dynamic) -> pubsub.Message

/// Track a presence in a topic
///
/// Returns a reference string (the pid) that can be used to untrack later.
///
/// Panics if the presence actor is unavailable or does not reply within 5 seconds.
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
///
/// Panics if the presence actor is unavailable or does not reply within 5 seconds.
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
///
/// Panics if the presence actor is unavailable or does not reply within 5 seconds.
pub fn untrack_all(presence: Presence, pid: String) -> Nil {
  process.call(presence.subject, 5000, fn(reply) { UntrackAll(pid, reply) })
}

/// List all presences for a topic
///
/// Panics if the presence actor is unavailable or does not reply within 5 seconds.
pub fn list(presence: Presence, topic: String) -> List(PresenceEntry) {
  process.call(presence.subject, 5000, fn(reply) { List(topic, reply) })
}

/// Get presences for a specific key within a topic
///
/// Panics if the presence actor is unavailable or does not reply within 5 seconds.
pub fn get_by_key(
  presence: Presence,
  topic: String,
  key: String,
) -> List(#(String, json.Json)) {
  process.call(presence.subject, 5000, fn(reply) { GetByKey(topic, key, reply) })
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
      maybe_invoke_on_diff(
        actor_state.config,
        single_join_diff(topic, key, pid, meta),
      )
      logger
      |> log.debug("Presence tracked", [
        #("topic", topic),
        #("key", key),
        #("pid", pid),
      ])
      process.send(reply, pid)
      actor.continue(ActorState(..actor_state, crdt: new_crdt, dirty: True))
    }

    Untrack(topic, key, pid, reply) -> {
      let diff = leave_diff(actor_state.crdt, topic, key, pid)
      let new_crdt = state.leave(actor_state.crdt, pid, topic, key)
      maybe_invoke_on_diff(actor_state.config, diff)
      logger
      |> log.debug("Presence untracked", [
        #("topic", topic),
        #("key", key),
        #("pid", pid),
      ])
      process.send(reply, Nil)
      actor.continue(ActorState(..actor_state, crdt: new_crdt, dirty: True))
    }

    UntrackAll(pid, reply) -> {
      let diff = leave_all_diff(actor_state.crdt, pid)
      let new_crdt = state.leave_by_pid(actor_state.crdt, pid)
      maybe_invoke_on_diff(actor_state.config, diff)
      process.send(reply, Nil)
      actor.continue(ActorState(..actor_state, crdt: new_crdt, dirty: True))
    }

    List(topic, reply) -> {
      let entries =
        state.get_by_topic(actor_state.crdt, topic)
        |> list.map(fn(t) {
          PresenceEntry(session_id: t.0, key: t.1, meta: t.2)
        })
      process.send(reply, entries)
      actor.continue(actor_state)
    }

    GetByKey(topic, key, reply) -> {
      let entries = state.get_by_key(actor_state.crdt, topic, key)
      process.send(reply, entries)
      actor.continue(actor_state)
    }

    BroadcastTick -> {
      case actor_state.config.pubsub, actor_state.self_subject {
        Some(ps), Some(subject) -> {
          let new_state = maybe_broadcast_state(actor_state, ps)
          schedule_broadcast_tick(
            subject,
            actor_state.config.broadcast_interval_ms,
          )
          actor.continue(new_state)
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

fn single_join_diff(
  topic: String,
  key: String,
  pid: String,
  meta: json.Json,
) -> Diff {
  Diff(
    joins: dict.from_list([
      #(topic, [
        PresenceEntry(session_id: pid, key: key, meta: meta),
      ]),
    ]),
    leaves: dict.new(),
  )
}

fn leave_diff(
  crdt: state.State,
  topic: String,
  key: String,
  pid: String,
) -> Diff {
  let leaves =
    state.get_by_key(crdt, topic, key)
    |> list.filter(fn(entry) { entry.0 == pid })
    |> list.map(fn(entry) {
      PresenceEntry(session_id: entry.0, key: key, meta: entry.1)
    })

  Diff(joins: dict.new(), leaves: topic_entries(topic, leaves))
}

fn leave_all_diff(crdt: State, pid: String) -> Diff {
  let leaves =
    state.online_list(crdt)
    |> list.filter(fn(entry) { entry.0 == pid })
    |> list.fold(dict.new(), fn(grouped, entry) {
      let #(_, topic, key, meta) = entry
      let existing =
        dict.get(grouped, topic)
        |> result.unwrap([])
      dict.insert(grouped, topic, [
        PresenceEntry(session_id: pid, key: key, meta: meta),
        ..existing
      ])
    })

  Diff(joins: dict.new(), leaves: leaves)
}

fn topic_entries(
  topic: String,
  entries: List(PresenceEntry),
) -> Dict(String, List(PresenceEntry)) {
  case entries {
    [] -> dict.new()
    _ -> dict.from_list([#(topic, entries)])
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
      let reason_str = case reason {
        SyncDecodeFailed -> "JSON parse or decode failed"
        UnknownEnvelopeVersion(version) ->
          "Unknown envelope version: " <> int.to_string(version)
      }
      let logger = internal.logger("beryl.presence")
      logger
      |> log.warn("Failed to decode presence sync message", [
        #("reason", reason_str),
        #("payload_length", int.to_string(string.length(payload_str))),
      ])
      actor.continue(actor_state)
    }
    Ok(#(_sender, remote_state)) -> {
      let #(new_crdt, state_diff) =
        state.merge_with_diff(actor_state.crdt, remote_state)
      let diff = wrap_state_diff(state_diff)
      let changed = !{ dict.is_empty(diff.joins) && dict.is_empty(diff.leaves) }
      maybe_invoke_on_diff(actor_state.config, diff)
      actor.continue(
        ActorState(
          ..actor_state,
          crdt: new_crdt,
          dirty: actor_state.dirty || changed,
        ),
      )
    }
  }
}

/// Errors produced when parsing a presence sync envelope.
type SyncEnvelopeError {
  /// The payload could not be parsed or decoded as a sync envelope.
  SyncDecodeFailed
  /// The envelope declared a version this node does not understand.
  UnknownEnvelopeVersion(Int)
}

/// Parse the sync envelope JSON: {"v": 1, "sender": "...", "state": {...}}
/// State is decoded directly as a nested object (not double-encoded string).
/// Rejects envelopes with unknown version numbers.
fn parse_sync_envelope(
  payload_str: String,
) -> Result(#(String, State), SyncEnvelopeError) {
  let decoder = {
    use v <- gdecode.field("v", gdecode.int)
    use sender <- gdecode.field("sender", gdecode.string)
    use remote_state <- gdecode.field("state", state_json.decoder())
    gdecode.success(#(v, sender, remote_state))
  }
  case json.parse(payload_str, decoder) {
    Error(_) -> Error(SyncDecodeFailed)
    Ok(#(1, sender, remote_state)) -> Ok(#(sender, remote_state))
    Ok(#(v, _, _)) -> Error(UnknownEnvelopeVersion(v))
  }
}
