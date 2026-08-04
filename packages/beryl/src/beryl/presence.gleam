//// Presence - Distributed presence tracking backed by a CRDT
////
//// Wraps the pure `lattice_presence/presence_state` CRDT in an OTP actor that:
//// - Handles track/untrack calls
//// - Periodically broadcasts state via PubSub for cross-node replication
//// - Receives remote state from PubSub and merges it internally
//// - Invokes `on_diff` callback when merges produce non-empty diffs
////
//// Presence is independent of the Beryl runtime. Start the actor from a
//// long-lived application process and include it in the application's
//// supervision arrangement as appropriate.
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
import gleam/dynamic.{type Dynamic}
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
/// or depend on the runtime representation. It carries both the actor's
/// subject (for the still-synchronous `track`/`untrack`/`untrack_all`) and a
/// reference to the actor-owned ETS read model that `list`, `get_by_key`,
/// and `count` read directly, without going through the actor mailbox.
pub opaque type Presence {
  Presence(subject: Subject(Message), read_table: Dynamic)
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
/// Build configs with `default_config` and the `with_*` functions so beryl can
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
  BroadcastTick
  /// Incoming PubSub sync message from a remote replica
  RemoteSync(pubsub_msg: pubsub.Message(SyncPayload))
  /// Test-only: holds the mailbox busy (see `block_for_test`) so tests can
  /// prove `list`/`get_by_key`/`count` stay responsive without touching it.
  /// Never sent by production code.
  Block(ms: Int, reply: Subject(Nil))
}

// ── Read model (ETS) ─────────────────────────────────────────────────────────
//
// `list`, `get_by_key`, and `count` read a materialized snapshot per topic
// from an ETS table the actor owns, rather than calling the actor. Only the
// actor process ever writes to this table, and only after a local mutation,
// remote merge, or replica-pruning operation has produced a complete new
// CRDT state — so readers never observe a partially updated topic. The
// table's lifetime is tied to the actor process: it is destroyed
// automatically when the actor stops, so a dead actor's reads fail
// explicitly (via `TableGone`) instead of silently returning stale or empty
// data.
//
// Each topic's row stores its entry count alongside its entry list (rather
// than deriving the count from the list on read) so `count` can fetch just
// the count field via `ets:lookup_element/4` -- O(1) and without copying the
// entry list out of the table -- instead of paying `list.length` (and a full
// list copy) on every call the way `list(presence, topic) |> list.length`
// would.

/// The outcome of looking up a topic's materialized entries. Constructed
/// directly by `beryl_presence_read_ffi` (its runtime representation must
/// match this type's constructors exactly: `Found(x)` as `{found, x}`,
/// `NotFound` as `not_found`, `TableGone` as `table_gone`).
type TopicLookup {
  Found(List(PresenceEntry))
  NotFound
  TableGone
}

/// The outcome of looking up a topic's materialized count. Constructed
/// directly by `beryl_presence_read_ffi` (its runtime representation must
/// match this type's constructors exactly: `CountFound(n)` as
/// `{count_found, n}`, `CountTableGone` as `count_table_gone`). A missing
/// topic reads as `CountFound(0)`, not an error -- the count field defaults
/// to `0` in the FFI, since "never tracked" and "empty" mean the same thing
/// to a caller of `count`.
type CountLookup {
  CountFound(Int)
  CountTableGone
}

@external(erlang, "beryl_presence_read_ffi", "new_table")
fn ffi_new_read_table() -> Dynamic

@external(erlang, "beryl_presence_read_ffi", "put_topic")
fn ffi_put_topic(
  table: Dynamic,
  topic: String,
  count: Int,
  entries: List(PresenceEntry),
) -> Nil

@external(erlang, "beryl_presence_read_ffi", "delete_topic")
fn ffi_delete_topic(table: Dynamic, topic: String) -> Nil

@external(erlang, "beryl_presence_read_ffi", "get_topic")
fn ffi_get_topic(table: Dynamic, topic: String) -> TopicLookup

@external(erlang, "beryl_presence_read_ffi", "get_count")
fn ffi_get_count(table: Dynamic, topic: String) -> CountLookup

/// Materialize a topic's current entries (and their count) from `crdt` into
/// the read model, or remove its snapshot entirely once it has no entries
/// left, so a missing topic is only ever "no snapshot recorded", never a
/// stale empty leftover.
fn publish_topic(table: Dynamic, crdt: State, topic: String) -> Nil {
  let entries =
    state.get_by_topic(crdt, topic)
    |> list.map(fn(t) { PresenceEntry(session_id: t.0, key: t.1, meta: t.2) })
  case entries {
    [] -> ffi_delete_topic(table, topic)
    _ -> ffi_put_topic(table, topic, list.length(entries), entries)
  }
}

/// Republish every topic named in `topics` from `crdt`. Used after
/// operations (remote merges, replica pruning) that can touch several
/// topics at once.
fn publish_topics(table: Dynamic, crdt: State, topics: List(String)) -> Nil {
  list.each(topics, fn(topic) { publish_topic(table, crdt, topic) })
}

/// Read a topic's materialized entries directly from the read model.
///
/// Panics if the read model table is unavailable, i.e. the presence actor
/// that owns it is no longer running.
fn read_entries(presence: Presence, topic: String) -> List(PresenceEntry) {
  case ffi_get_topic(presence.read_table, topic) {
    Found(entries) -> entries
    NotFound -> []
    TableGone -> {
      // nolint: avoid_panic -- read storage being gone means the owning actor died; matches the existing "actor unavailable" panic contract of track/untrack/untrack_all
      panic as "presence read storage is unavailable: the presence actor is not running"
    }
  }
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
    /// The ETS table backing the read model that `list`, `get_by_key`, and
    /// `count` read directly. Owned by this actor process; see `publish_topic`.
    read_table: Dynamic,
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

@internal
pub fn subject(presence: Presence) -> Subject(Message) {
  presence.subject
}

@internal
pub fn block_for_test(presence: Presence, ms: Int) -> Subject(Nil) {
  let reply = process.new_subject()
  process.send(presence.subject, Block(ms, reply))
  reply
}

/// Start the presence actor
pub fn start(config: Config) -> Result(Presence, PresenceError) {
  build_presence(config)
  |> actor.start
  |> result.map(fn(started) {
    let #(subject, read_table) = started.data
    Presence(subject: subject, read_table: read_table)
  })
  |> result.map_error(fn(error) {
    PresenceStartFailed(beryl_error.from_actor_start_error(error))
  })
}

fn build_presence(
  config: Config,
) -> actor.Builder(ActorState, Message, #(Subject(Message), Dynamic)) {
  // Each actor start is a fresh CRDT incarnation. Reusing the bare replica
  // name after a restart would reset its clocks while peers still remember
  // the old ones: new joins would be silently filtered as already-seen,
  // and the previous incarnation's entries would resurrect via merges.
  // A unique per-start suffix makes every incarnation a distinct replica;
  // `prune_superseded` cleans up the dead predecessors.
  let crdt = state.new(incarnate_replica(config.replica))

  actor.new_with_initialiser(5000, fn(subject) {
    // Created here, in the actor process itself, so the read model's
    // lifetime is tied to the actor: it is destroyed automatically if this
    // process stops or crashes, matching the "actor unavailable" failure
    // mode readers already get from a dead actor.
    let read_table = ffi_new_read_table()
    let initial =
      ActorState(
        crdt: crdt,
        config: config,
        self_subject: Some(subject),
        dirty: False,
        refs: dict.new(),
        read_table: read_table,
      )

    case config.pubsub {
      Some(ps) -> {
        // Subscribe to the well-known sync topic for replication
        let sub = pubsub.subscriber(ps)
        pubsub.join(sub, sync_topic)
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
          |> pubsub.selecting(sub, RemoteSync)

        // Schedule the first broadcast tick if enabled
        schedule_broadcast_tick(subject, config.broadcast_interval_ms)

        actor.initialised(initial)
        |> actor.selecting(selector)
        |> actor.returning(#(subject, read_table))
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
            read_table: read_table,
          )
        actor.initialised(no_pubsub_initial)
        |> actor.returning(#(subject, read_table))
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
///
/// Returns the pruned CRDT along with every topic its pruning touched, so
/// the caller can republish exactly those topics' read-model snapshots.
fn prune_superseded(
  config: Config,
  crdt: State,
  live: List(String),
) -> #(State, List(String)) {
  let stale =
    dict.keys(state.compacted_clocks(crdt))
    |> list.filter(fn(replica) {
      list.any(live, fn(live_replica) {
        replica != live_replica
        && base_replica(replica) == base_replica(live_replica)
      })
    })
  list.fold(stale, #(crdt, []), fn(acc, replica) {
    let #(crdt, touched_topics) = acc
    let #(crdt, down_diff) = state.replica_down(crdt, replica)
    let diff = wrap_state_diff(down_diff)
    maybe_invoke_on_diff(config, diff)
    let crdt = state.remove_down_replica(crdt, replica)
    let newly_touched =
      list.append(dict.keys(diff.joins), dict.keys(diff.leaves))
    #(crdt, list.append(touched_topics, newly_touched))
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

/// List all presences for a topic.
///
/// Reads the actor-owned read model directly (an ETS snapshot materialized
/// after each mutation, merge, or prune) rather than calling the actor, so
/// this never waits on the actor mailbox.
///
/// Panics if the presence read model is unavailable (the presence actor is
/// not running).
pub fn list(presence: Presence, topic: String) -> List(PresenceEntry) {
  read_entries(presence, topic)
}

/// Get presences for a specific key within a topic.
///
/// Reads the actor-owned read model directly (an ETS snapshot materialized
/// after each mutation, merge, or prune) rather than calling the actor, so
/// this never waits on the actor mailbox.
///
/// Panics if the presence read model is unavailable (the presence actor is
/// not running).
pub fn get_by_key(
  presence: Presence,
  topic: String,
  key: String,
) -> List(#(String, json.Json)) {
  read_entries(presence, topic)
  |> list.filter(fn(entry) { entry.key == key })
  |> list.map(fn(entry) { #(entry.session_id, entry.meta) })
}

/// Count presences in a topic.
///
/// Equivalent to `list(presence, topic) |> list.length`, but O(1): it reads
/// the materialized count directly from the read model via
/// `ets:lookup_element/4` instead of building (and copying) the entry list
/// just to measure it.
///
/// Reads the actor-owned read model directly (an ETS snapshot materialized
/// after each mutation, merge, or prune) rather than calling the actor, so
/// this never waits on the actor mailbox.
///
/// Panics if the presence read model is unavailable (the presence actor is
/// not running).
pub fn count(presence: Presence, topic: String) -> Int {
  case ffi_get_count(presence.read_table, topic) {
    CountFound(count) -> count
    CountTableGone -> {
      // nolint: avoid_panic -- read storage being gone means the owning actor died; matches the existing "actor unavailable" panic contract of track/untrack/untrack_all
      panic as "presence read storage is unavailable: the presence actor is not running"
    }
  }
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
        #("session_id", pid),
        #("ref", ref),
      ])
      let new_refs =
        dict.insert(
          actor_state.refs,
          ref,
          TrackedPresence(topic: topic, key: key, session_id: pid),
        )
      // Publish the read model before replying, so a `track(); list()`
      // caller always observes the entry it just tracked.
      publish_topic(actor_state.read_table, new_crdt, topic)
      process.send(reply, ref)
      actor.continue(
        ActorState(..actor_state, crdt: new_crdt, dirty: True, refs: new_refs),
      )
    }

    Untrack(ref, reply) -> {
      case dict.get(actor_state.refs, ref) {
        Error(Nil) -> {
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
            #("session_id", session_id),
            #("ref", ref),
          ])
          // Publish before replying, so a `untrack(); list()` caller always
          // observes the removal.
          publish_topic(actor_state.read_table, new_crdt, topic)
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
      // A single session can hold presences in several topics; republish
      // every topic the leave touched (from the pre-mutation diff) before
      // replying.
      publish_topics(actor_state.read_table, new_crdt, dict.keys(diff.leaves))
      process.send(reply, Nil)
      actor.continue(
        ActorState(..actor_state, crdt: new_crdt, dirty: True, refs: new_refs),
      )
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

    Block(ms, reply) -> {
      // Test-only: deliberately holds the mailbox busy. See `block_for_test`.
      process.sleep(ms)
      process.send(reply, Nil)
      actor.continue(actor_state)
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
  // Merge, diff, on_diff, prune, and the read-model publication that follows
  // all run inside a crash boundary. The remote state originates from
  // another cluster node (possibly a mixed version, a compromised peer, or a
  // malformed dynamic value coerced from the wire); an exception here must
  // not terminate the shared presence actor. On failure we return the
  // previous, unchanged `actor_state` so invalid sync input cannot partially
  // mutate presence state or its read model: the read model is only
  // republished once merge, on_diff, and prune have all completed
  // successfully below.
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
      let #(new_crdt, pruned_topics) =
        prune_superseded(actor_state.config, new_crdt, [
          sender,
          state.replica(new_crdt),
        ])
      // Republish every topic touched by either the merge or the prune,
      // from the final crdt, in one pass — readers only ever see the
      // fully-merged-and-pruned snapshot, never an intermediate one.
      let touched_topics =
        list.append(dict.keys(diff.joins), dict.keys(diff.leaves))
        |> list.append(pruned_topics)
        |> unique_strings(set.new(), [])
      publish_topics(actor_state.read_table, new_crdt, touched_topics)
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
