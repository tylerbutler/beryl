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
import beryl/wire
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode as gdecode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lattice_presence/presence_state as state

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
  |> unique_strings(set.new(), [])
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

fn unique_strings(
  values: List(String),
  seen: Set(String),
  unique: List(String),
) -> List(String) {
  case values {
    [] -> list.reverse(unique)
    [value, ..rest] ->
      case set.contains(seen, value) {
        True -> unique_strings(rest, seen, unique)
        False ->
          unique_strings(rest, set.insert(seen, value), [value, ..unique])
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

// nolint: unused_exports -- package-internal, hidden from public docs with @internal; test modules construct it directly to exercise the version guard
/// The replication envelope carried over PubSub between presence replicas.
///
/// Sent as a native BEAM term (no JSON encoding), so `v` is presence's own
/// version guard: a node that does not recognise `v` discards the message
/// rather than risk interpreting a shape it wasn't built to read. Bump it if
/// this envelope's fields ever need to change.
@internal
pub type SyncPayload {
  SyncPayload(v: Int, sender: String, state: state.State)
}

/// Configuration for starting presence.
///
/// Build configs with `default_config` and the `with_*` functions so Beryl can
/// add future options without exposing record fields as public API.
pub opaque type Config {
  Config(
    /// PubSub instance for cross-node replication
    pubsub: Option(PubSub(SyncPayload)),
    /// This node's replica base name. Must identify at most one live node
    /// in the cluster. Each actor start derives a unique incarnation name
    /// from it (`base@suffix`), so restarting a node never reuses the
    /// previous incarnation's CRDT clocks; state from older incarnations
    /// of the same base is pruned automatically. Two *live* nodes sharing
    /// a base will continuously prune each other — do not do that.
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
  Untrack(ref: String, reply: Subject(Nil))
  UntrackAll(pid: String, reply: Subject(Nil))
  List(topic: String, reply: Subject(List(PresenceEntry)))
  GetByKey(
    topic: String,
    key: String,
    reply: Subject(List(#(String, json.Json))),
  )
  BroadcastTick
  /// Incoming PubSub sync message from a remote replica
  RemoteSync(pubsub_msg: pubsub.Message(SyncPayload))
}

/// A tracked presence's location within the CRDT, keyed by tracking ref.
type TrackedPresence {
  TrackedPresence(topic: String, key: String, session_id: String)
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
    /// Maps each server-generated tracking ref to the presence it created, so
    /// `untrack` can locate the correct CRDT entry to leave. Populated on
    /// `Track` and pruned on `Untrack`/`UntrackAll`.
    refs: Dict(String, TrackedPresence),
  )
}

/// Default configuration (no PubSub).
///
/// The broadcast interval defaults to 1500 ms so that adding `with_pubsub`
/// yields working two-way replication out of the box; without PubSub the
/// interval is unused. Use `with_broadcast_interval(0)` to disable periodic
/// broadcasts and control replication manually.
pub fn default_config(replica: String) -> Config {
  Config(
    pubsub: None,
    replica: replica,
    broadcast_interval_ms: 1500,
    on_diff: None,
  )
}

/// Enable PubSub replication for presence.
pub fn with_pubsub(config: Config, pubsub: PubSub(SyncPayload)) -> Config {
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

// nolint: unused_exports -- package-internal constructor for supervised presence; hidden from public docs with @internal
/// Start the presence actor with a registered name. Package-internal: used by
/// `beryl/supervisor`; end users get supervision via `supervisor.start`.
@internal
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
  // Each actor start is a fresh CRDT incarnation. Reusing the bare replica
  // name after a restart would reset its clocks while peers still remember
  // the old ones: new joins would be silently filtered as already-seen,
  // and the previous incarnation's entries would resurrect via merges.
  // A unique per-start suffix makes every incarnation a distinct replica;
  // `prune_superseded` cleans up the dead predecessors.
  let crdt = state.new(incarnate_replica(config.replica))

  actor.new_with_initialiser(5000, fn(subject) {
    let initial =
      ActorState(
        crdt: crdt,
        config: config,
        self_subject: Some(subject),
        dirty: False,
        refs: dict.new(),
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

        // Build selector: handle actor subject messages + PubSub sync messages
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> pubsub.selecting(RemoteSync)

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
            refs: dict.new(),
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
fn maybe_broadcast_state(
  actor_state: ActorState,
  ps: PubSub(SyncPayload),
) -> ActorState {
  use <- bool.guard(when: !actor_state.dirty, return: actor_state)
  let payload =
    SyncPayload(
      v: 1,
      // The sender is the full incarnation name; receivers use its base to
      // prune state left behind by this node's previous incarnations.
      sender: state.replica(actor_state.crdt),
      state: actor_state.crdt,
    )

  pubsub.broadcast_from(ps, process.self(), sync_topic, sync_event, payload)

  ActorState(..actor_state, dirty: False)
}

/// Schedule the next broadcast tick if the interval is positive
fn schedule_broadcast_tick(subject: Subject(Message), interval_ms: Int) -> Nil {
  use <- bool.guard(when: interval_ms <= 0, return: Nil)
  let _timer = process.send_after(subject, interval_ms, BroadcastTick)
  Nil
}

/// Generate a unique, opaque tracking ref for a presence.
///
/// Uses 16 bytes of cryptographically strong randomness (base16-encoded), which
/// makes collisions between refs negligibly unlikely and keeps them unguessable.
fn generate_ref() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode()
}

/// Separates a replica base name from its per-start incarnation suffix.
const incarnation_separator = "@"

/// Derive a unique incarnation name for this actor start.
fn incarnate_replica(base: String) -> String {
  base
  <> incarnation_separator
  <> bit_array.base16_encode(crypto.strong_random_bytes(4))
}

/// Recover the configured base from an incarnation-qualified replica name.
///
/// The suffix we mint never contains the separator, so everything before
/// the last separator is the base — even when the base itself contains one
/// (e.g. Erlang-style `app@host` names). Names without a separator (from
/// nodes running older beryl versions) are their own base.
fn base_replica(replica: String) -> String {
  case list.reverse(string.split(replica, incarnation_separator)) {
    [_suffix, ..rest] if rest != [] ->
      string.join(list.reverse(rest), incarnation_separator)
    _ -> replica
  }
}

/// Prune CRDT state left behind by dead incarnations of the given live
/// replicas (the sync sender and ourselves).
///
/// This is the beryl-side workaround for replica reuse across restarts
/// (first-class incarnations are proposed upstream in lattice): any replica
/// sharing a live replica's base but not its suffix belongs to a dead
/// predecessor. Hide it (emitting leave diffs through `on_diff`) and prune
/// it. A lagging peer can briefly resurrect pruned entries until it
/// observes the live incarnation itself; the prune re-applies on every
/// sync, so the cluster converges within about one broadcast interval.
fn prune_superseded(config: Config, crdt: State, live: List(String)) -> State {
  let stale =
    dict.keys(state.compacted_clocks(crdt))
    |> list.filter(fn(replica) {
      list.any(live, fn(live_replica) {
        replica != live_replica
        && base_replica(replica) == base_replica(live_replica)
      })
    })
  list.fold(stale, crdt, fn(crdt, replica) {
    let #(crdt, down_diff) = state.replica_down(crdt, replica)
    maybe_invoke_on_diff(config, wrap_state_diff(down_diff))
    state.remove_down_replica(crdt, replica)
  })
}

/// Merge the server-generated tracking ref into the tracked meta as
/// `phx_ref`, matching Phoenix behaviour. Phoenix client `Presence` helpers
/// identify individual metas by `phx_ref` when applying diffs; without it a
/// single leave would remove every meta stored under the same key. Any
/// client-supplied `phx_ref` is replaced. Non-object metas are stored
/// unchanged (Phoenix requires object metas for its Presence helpers).
fn meta_with_phx_ref(meta: json.Json, ref: String) -> json.Json {
  json.parse(
    from: json.to_string(meta),
    using: gdecode.dict(gdecode.string, gdecode.dynamic),
  )
  |> result.map(fn(fields) {
    fields
    |> dict.delete("phx_ref")
    |> dict.to_list
    |> list.map(fn(field) { #(field.0, wire.dynamic_to_json(field.1)) })
    |> list.append([#("phx_ref", json.string(ref))])
    |> json.object
  })
  |> result.unwrap(meta)
}

/// Track a presence in a topic.
///
/// `session_id` identifies the session (e.g. socket) that owns this presence
/// and is the value `untrack_all` matches on when the session disconnects.
///
/// Returns a server-generated tracking ref: an opaque, unique handle for this
/// specific presence. Pass it to `untrack` to remove exactly this entry later.
/// The ref is not the session id — it is minted by the presence actor and is
/// only meaningful to that actor. The ref is also merged into object metas as
/// `phx_ref` for Phoenix client compatibility.
///
/// Panics if the presence actor is unavailable or does not reply within 5 seconds.
pub fn track(
  presence: Presence,
  topic: String,
  key: String,
  session_id: String,
  meta: json.Json,
) -> String {
  process.call(presence.subject, 5000, fn(reply) {
    Track(topic, key, session_id, meta, reply)
  })
}

/// Untrack a specific presence using the ref returned by `track`.
///
/// Removing an unknown or already-removed ref is a harmless no-op.
///
/// Panics if the presence actor is unavailable or does not reply within 5 seconds.
pub fn untrack(presence: Presence, ref: String) -> Nil {
  process.call(presence.subject, 5000, fn(reply) { Untrack(ref, reply) })
}

/// Untrack all presences for a session (e.g., when a socket disconnects)
///
/// Panics if the presence actor is unavailable or does not reply within 5 seconds.
pub fn untrack_all(presence: Presence, session_id: String) -> Nil {
  process.call(presence.subject, 5000, fn(reply) {
    UntrackAll(session_id, reply)
  })
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
      let ref = generate_ref()
      let meta = meta_with_phx_ref(meta, ref)
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
        #("ref", ref),
      ])
      let new_refs =
        dict.insert(
          actor_state.refs,
          ref,
          TrackedPresence(topic: topic, key: key, session_id: pid),
        )
      process.send(reply, ref)
      actor.continue(
        ActorState(..actor_state, crdt: new_crdt, dirty: True, refs: new_refs),
      )
    }

    Untrack(ref, reply) -> {
      case dict.get(actor_state.refs, ref) {
        Error(_) -> {
          // Unknown or already-removed ref: nothing to do.
          process.send(reply, Nil)
          actor.continue(actor_state)
        }
        Ok(TrackedPresence(topic, key, session_id)) -> {
          let diff = leave_diff(actor_state.crdt, topic, key, session_id)
          let new_crdt = state.leave(actor_state.crdt, session_id, topic, key)
          maybe_invoke_on_diff(actor_state.config, diff)
          logger
          |> log.debug("Presence untracked", [
            #("topic", topic),
            #("key", key),
            #("pid", session_id),
            #("ref", ref),
          ])
          process.send(reply, Nil)
          actor.continue(
            ActorState(
              ..actor_state,
              crdt: new_crdt,
              dirty: True,
              refs: dict.delete(actor_state.refs, ref),
            ),
          )
        }
      }
    }

    UntrackAll(pid, reply) -> {
      let diff = leave_all_diff(actor_state.crdt, pid)
      let new_crdt = state.leave_by_pid(actor_state.crdt, pid)
      maybe_invoke_on_diff(actor_state.config, diff)
      // Drop any refs that pointed at the removed session so they cannot leak
      // or later leave presences they no longer own.
      let new_refs =
        dict.filter(actor_state.refs, fn(_ref, tracked) {
          tracked.session_id != pid
        })
      process.send(reply, Nil)
      actor.continue(
        ActorState(..actor_state, crdt: new_crdt, dirty: True, refs: new_refs),
      )
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
        True -> handle_sync_payload(actor_state, pubsub_msg.payload)
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

/// Check the envelope version and merge the remote state.
/// Self-delivery is already prevented by broadcast_from at the PubSub layer.
fn handle_sync_payload(
  actor_state: ActorState,
  payload: SyncPayload,
) -> actor.Next(ActorState, Message) {
  case payload.v {
    1 -> merge_remote_sync(actor_state, payload.sender, payload.state)
    version -> {
      let logger = internal.logger("beryl.presence")
      logger
      |> log.warn(
        "Ignored presence sync message with unknown envelope version",
        [#("version", int.to_string(version))],
      )
      actor.continue(actor_state)
    }
  }
}

fn merge_remote_sync(
  actor_state: ActorState,
  sender: String,
  remote_state: State,
) -> actor.Next(ActorState, Message) {
  // Merge, diff, on_diff, and prune all run inside a crash boundary. The
  // remote state originates from another cluster node (possibly a mixed
  // version, a compromised peer, or a malformed dynamic value coerced from
  // the wire); an exception here must not terminate the shared presence
  // actor. On failure we return the previous, unchanged `actor_state` so
  // invalid sync input cannot partially mutate presence state.
  let processed =
    internal.rescue(fn() {
      let #(new_crdt, state_diff) =
        state.merge_with_diff(actor_state.crdt, remote_state)
      let diff = wrap_state_diff(state_diff)
      let changed = !{ dict.is_empty(diff.joins) && dict.is_empty(diff.leaves) }
      maybe_invoke_on_diff(actor_state.config, diff)
      // The merge may have (re)admitted state from dead incarnations —
      // the sender's predecessors, or our own pre-restart self echoed back
      // by a peer. Prune anything superseded by the two incarnations known
      // to be live right now: the sender and ourselves.
      let new_crdt =
        prune_superseded(actor_state.config, new_crdt, [
          sender,
          state.replica(new_crdt),
        ])
      ActorState(
        ..actor_state,
        crdt: new_crdt,
        dirty: actor_state.dirty || changed,
      )
    })
  case processed {
    Ok(next_state) -> actor.continue(next_state)
    Error(crash) -> {
      let logger = internal.logger("beryl.presence")
      logger
      |> log.error("Remote presence sync dropped: processing failed", [
        #("crash", crash),
      ])
      actor.continue(actor_state)
    }
  }
}
