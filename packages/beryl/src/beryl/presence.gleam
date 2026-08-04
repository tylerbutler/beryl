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
///
/// ## Node affinity
///
/// `list`, `get_by_key`, and `count` read the ETS read model directly
/// in-process, which only works for ETS tables local to the calling node.
/// Do not send this handle to, or otherwise use it from, a process on a
/// different BEAM node: `track`/`untrack`/`untrack_all` would still reach
/// the owning actor over distribution (they go through its `Subject`), but
/// the read functions would be looking up a table reference that names
/// nothing on that node (or, if the identifier happens to collide with an
/// unrelated local table, something else entirely), so they would panic or
/// read the wrong data. Keep a Presence handle on the node where `start`
/// created it, and use PubSub replication (`with_pubsub`) to share presence
/// state across nodes instead.
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
    /// Runs synchronously on the actor, strictly before the read model is
    /// republished for the topics the diff touches -- see `with_on_diff`.
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
  /// Asynchronous track used by the runtime's effect interpreter. The new
  /// entry supersedes every ref this actor still holds for the same logical
  /// `(pid, topic, key)` — `replace`, when the caller knows the previous
  /// ref, plus any ref the caller has lost track of (an earlier operation
  /// it timed out on, say). All of that happens in this one actor turn, so
  /// the topic never materializes an intermediate snapshot without the key,
  /// and the tuple never carries two live refs at once. See the
  /// `SupersedeSameKey` docs for why the sweep, not just `replace`, is
  /// what makes a late compensating untrack safe.
  TrackAsync(
    topic: String,
    key: String,
    pid: String,
    meta: json.Json,
    replace: Option(String),
    tag: String,
    op_id: Int,
    reply: Subject(MutationAck),
  )
  /// Asynchronous batch untrack by ref, used by the runtime for both the
  /// `PresenceUntrack` effect and topic-close cleanup. Every ref is removed
  /// in one turn, producing one `on_diff` and one read-model publication
  /// per touched topic.
  UntrackAsync(
    refs: List(String),
    tag: String,
    op_id: Int,
    reply: Subject(MutationAck),
  )
  /// Fire-and-forget session sweep, used by the runtime while shutting
  /// down and unable to wait for an acknowledgement.
  UntrackAllAsync(pid: String)
  BroadcastTick
  /// Incoming PubSub sync message from a remote replica
  RemoteSync(pubsub_msg: pubsub.Message(SyncPayload))
}

// nolint: unused_exports -- package-internal async mutation protocol for the runtime; hidden from public docs with @internal
/// Acknowledgement of an asynchronous presence mutation.
///
/// `tag` and `op_id` are echoed back verbatim from the request so the
/// caller can route the acknowledgement to the right waiter and discard
/// acknowledgements for operations it has already given up on.
@internal
pub type MutationAck {
  MutationAck(tag: String, op_id: Int, outcome: MutationOutcome)
}

// nolint: unused_exports -- package-internal async mutation protocol for the runtime; hidden from public docs with @internal
/// What an acknowledged mutation produced.
@internal
pub type MutationOutcome {
  /// A track completed: the generated ref and the meta as actually stored
  /// (the caller's meta with `phx_ref` merged in), so the caller's own
  /// bookkeeping, diffs, and later leaves all use identical metadata.
  Tracked(ref: String, meta: json.Json)
  /// An untrack batch completed.
  Untracked
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
// data. ETS tables (and this raw table reference) are node-local, so those
// same reads also fail explicitly if a `Presence` handle is ever used from a
// process on a different BEAM node than the one that started it — see the
// node affinity note on `Presence`.
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
/// Panics if the read model table is unavailable -- either because the
/// presence actor that owns it is no longer running, or because this
/// handle is being used from a process on a different BEAM node than the
/// one `start` was called on (see the node affinity note on `Presence`).
fn read_entries(presence: Presence, topic: String) -> List(PresenceEntry) {
  case ffi_get_topic(presence.read_table, topic) {
    Found(entries) -> entries
    NotFound -> []
    TableGone -> {
      // nolint: avoid_panic -- read storage being gone means either the owning actor died or this handle is being read from another node; matches the existing "actor unavailable" panic contract of track/untrack/untrack_all
      panic as "presence read storage is unavailable: either the presence actor is not running, or this handle was used from a process on another BEAM node than the one it was started on"
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
///
/// The callback runs synchronously on the presence actor, for both local
/// mutations (`track`/`untrack`/`untrack_all`, and the asynchronous
/// mutations the runtime issues for presence effects) and remote merges,
/// before the affected topics' read-model snapshots are (re)published and
/// before the triggering call replies or the mutation is acknowledged.
/// This ordering is identical for local and remote diffs -- there is no
/// divergent local-vs-remote behavior.
///
/// One consequence: if the callback reads presence state through the same
/// `Presence` handle (`list`, `get_by_key`, `count`) for a topic this diff
/// touches, it observes the *previous* snapshot -- the one from before this
/// diff -- not the one the diff itself is about to produce. Read the
/// entries and counts you need directly from the `Diff` argument (via
/// `diff_joins`/`diff_leaves`) instead of re-reading through `presence`
/// inside the callback.
///
/// Keep the callback fast and non-blocking: it runs on the actor process,
/// so a slow or blocking callback delays that topic's read-model publish,
/// the reply to (or acknowledgement of) the mutating operation, and every
/// other message queued behind it in the actor's mailbox (though concurrent
/// `list`/`get_by_key`/`count` reads from other processes are unaffected,
/// since those bypass the mailbox entirely). It no longer stalls a Beryl
/// runtime wholesale: only the socket whose presence effect is in flight
/// waits on it.
pub fn with_on_diff(config: Config, callback: fn(Diff) -> Nil) -> Config {
  Config(..config, on_diff: Some(callback))
}

// nolint: unused_exports -- package-internal accessor for replication tests; hidden from public docs with @internal
@internal
pub fn subject(presence: Presence) -> Subject(Message) {
  presence.subject
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

// ── Asynchronous mutation protocol (package-internal) ───────────────────────
//
// The runtime interprets presence effects from its single actor turn and
// must never block that actor on a `process.call`. These functions send the
// mutation and return immediately; the presence actor replies with a
// `MutationAck` to `reply` once the CRDT *and* the ETS read-model snapshot
// for every touched topic have been updated. They share the exact mutation
// logic used by the synchronous `track`/`untrack` above, so both entry
// points produce identical CRDT state, diffs, and read-model publications.

// nolint: unused_exports -- package-internal async mutation protocol for the runtime; hidden from public docs with @internal
/// Track a presence asynchronously. The new entry supersedes, atomically in
/// the same actor turn, both `replace` (a ref from a previous track of this
/// key, when the caller still knows it) and any *other* ref the actor still
/// holds for the same `(session_id, topic, key)` — including one from an
/// operation the caller timed out on and whose acknowledgement it has not
/// seen yet. A logical `(session_id, topic, key)` therefore never has two
/// live refs, so a late `untrack` of a superseded ref cannot remove the
/// newer entry (the CRDT removes by tuple, not by ref). The
/// acknowledgement carries the generated ref and the stored meta.
@internal
pub fn track_async(
  presence presence: Presence,
  topic topic: String,
  key key: String,
  session_id session_id: String,
  meta meta: json.Json,
  replace replace: Option(String),
  tag tag: String,
  op_id op_id: Int,
  reply reply: Subject(MutationAck),
) -> Nil {
  process.send(
    presence.subject,
    TrackAsync(
      topic: topic,
      key: key,
      pid: session_id,
      meta: meta,
      replace: replace,
      tag: tag,
      op_id: op_id,
      reply: reply,
    ),
  )
}

// nolint: unused_exports -- package-internal async mutation protocol for the runtime; hidden from public docs with @internal
/// Untrack a batch of refs asynchronously. Unknown or already-removed refs
/// are skipped; the whole batch is one actor turn, one `on_diff`, and one
/// read-model publication per touched topic.
@internal
pub fn untrack_async(
  presence presence: Presence,
  refs refs: List(String),
  tag tag: String,
  op_id op_id: Int,
  reply reply: Subject(MutationAck),
) -> Nil {
  process.send(
    presence.subject,
    UntrackAsync(refs: refs, tag: tag, op_id: op_id, reply: reply),
  )
}

// nolint: unused_exports -- package-internal async mutation protocol for the runtime; hidden from public docs with @internal
/// Sweep every presence a session still holds, without acknowledgement.
/// Used by the runtime while shutting down, when it can no longer wait.
@internal
pub fn untrack_all_async(presence: Presence, session_id: String) -> Nil {
  process.send(presence.subject, UntrackAllAsync(session_id))
}

// nolint: unused_exports -- package-internal liveness probe for the runtime; hidden from public docs with @internal
/// Whether the presence actor is still running.
///
/// The asynchronous protocol above cannot detect a dead actor (a send to a
/// dead process is silently dropped), so callers probe first rather than
/// waiting out an acknowledgement that can never arrive.
@internal
pub fn is_running(presence: Presence) -> Bool {
  case process.subject_owner(presence.subject) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}

/// List all presences for a topic.
///
/// Reads the actor-owned read model directly (an ETS snapshot materialized
/// after each mutation, merge, or prune) rather than calling the actor, so
/// this never waits on the actor mailbox.
///
/// Panics if the presence read model is unavailable -- either the presence
/// actor is not running, or this handle is being used from a process on
/// another BEAM node than the one it was started on (see the node affinity
/// note on `Presence`).
pub fn list(presence: Presence, topic: String) -> List(PresenceEntry) {
  read_entries(presence, topic)
}

/// Get presences for a specific key within a topic.
///
/// Reads the actor-owned read model directly (an ETS snapshot materialized
/// after each mutation, merge, or prune) rather than calling the actor, so
/// this never waits on the actor mailbox.
///
/// Panics if the presence read model is unavailable -- either the presence
/// actor is not running, or this handle is being used from a process on
/// another BEAM node than the one it was started on (see the node affinity
/// note on `Presence`).
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
/// Panics if the presence read model is unavailable -- either the presence
/// actor is not running, or this handle is being used from a process on
/// another BEAM node than the one it was started on (see the node affinity
/// note on `Presence`).
pub fn count(presence: Presence, topic: String) -> Int {
  case ffi_get_count(presence.read_table, topic) {
    CountFound(count) -> count
    CountTableGone -> {
      // nolint: avoid_panic -- read storage being gone means either the owning actor died or this handle is being read from another node; matches the existing "actor unavailable" panic contract of track/untrack/untrack_all
      panic as "presence read storage is unavailable: either the presence actor is not running, or this handle was used from a process on another BEAM node than the one it was started on"
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
      let #(new_state, ref, _meta) =
        do_track(actor_state, topic, key, pid, meta, SupersedeNothing)
      log_tracked(logger, topic, key, pid, ref)
      // The read model was published inside `do_track`, before this reply,
      // so a `track(); list()` caller always observes the entry it just
      // tracked.
      process.send(reply, ref)
      actor.continue(new_state)
    }

    TrackAsync(topic, key, pid, meta, replace, tag, op_id, reply) -> {
      let #(new_state, ref, stored_meta) =
        do_track(
          actor_state,
          topic,
          key,
          pid,
          meta,
          SupersedeSameKey(explicit: replace),
        )
      log_tracked(logger, topic, key, pid, ref)
      process.send(reply, MutationAck(tag, op_id, Tracked(ref, stored_meta)))
      actor.continue(new_state)
    }

    Untrack(ref, reply) -> {
      let new_state = do_untrack_refs(actor_state, [ref])
      process.send(reply, Nil)
      actor.continue(new_state)
    }

    UntrackAsync(refs, tag, op_id, reply) -> {
      let new_state = do_untrack_refs(actor_state, refs)
      process.send(reply, MutationAck(tag, op_id, Untracked))
      actor.continue(new_state)
    }

    UntrackAll(pid, reply) -> {
      let new_state = do_untrack_all(actor_state, pid)
      process.send(reply, Nil)
      actor.continue(new_state)
    }

    UntrackAllAsync(pid) -> actor.continue(do_untrack_all(actor_state, pid))

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

fn log_tracked(
  logger: log.Logger,
  topic: String,
  key: String,
  pid: String,
  ref: String,
) -> Nil {
  logger
  |> log.debug("Presence tracked", [
    #("topic", topic),
    #("key", key),
    #("pid", pid),
    #("ref", ref),
  ])
}

// ── Shared mutation core ────────────────────────────────────────────────────
//
// Every mutation entry point (synchronous call or asynchronous message)
// funnels through these functions, so the CRDT update, the `on_diff`
// invocation, and the read-model publication happen in exactly one order:
// mutate, invoke `on_diff`, publish every touched topic, and only then
// reply/acknowledge.

/// The result of removing a batch of refs from the CRDT.
type RemovedRefs {
  RemovedRefs(
    crdt: State,
    /// Entries actually removed, grouped by topic — the leave side of the
    /// diff, captured before each removal so metas are the stored ones.
    leaves: Dict(String, List(PresenceEntry)),
    /// The ref map with every removed ref dropped.
    refs: Dict(String, TrackedPresence),
    /// Topics touched by the removals (with duplicates).
    topics: List(String),
  )
}

fn remove_refs(
  crdt: State,
  refs: Dict(String, TrackedPresence),
  removing: List(String),
) -> RemovedRefs {
  list.fold(
    removing,
    RemovedRefs(crdt: crdt, leaves: dict.new(), refs: refs, topics: []),
    fn(acc, ref) {
      case dict.get(acc.refs, ref) {
        Error(Nil) -> acc
        Ok(TrackedPresence(topic, key, session_id)) -> {
          let removed =
            state.get_by_key(acc.crdt, topic, key)
            |> list.filter(fn(entry) { entry.0 == session_id })
            |> list.map(fn(entry) {
              PresenceEntry(session_id: entry.0, key: key, meta: entry.1)
            })
          let existing =
            dict.get(acc.leaves, topic)
            |> result.unwrap([])
          RemovedRefs(
            crdt: state.leave(acc.crdt, session_id, topic, key),
            leaves: case removed {
              [] -> acc.leaves
              _ ->
                dict.insert(acc.leaves, topic, list.append(existing, removed))
            },
            refs: dict.delete(acc.refs, ref),
            topics: [topic, ..acc.topics],
          )
        }
      }
    },
  )
}

/// Which refs a track supersedes in its own turn.
type Supersede {
  /// The public synchronous `track`: supersede nothing. Callers of the
  /// public API own their refs and remove them explicitly with `untrack`,
  /// and several refs for one key (each with its own `phx_ref` meta) is a
  /// meaningful, supported shape there.
  SupersedeNothing
  /// The runtime's asynchronous track: supersede `explicit` (the previous
  /// ref, when the caller still knows it) *and* every other ref this actor
  /// holds for the same `(pid, topic, key)`.
  ///
  /// The sweep is what keeps runtime-owned presence single-valued when the
  /// caller has *lost* a ref — an operation it timed out on and gave up,
  /// whose acknowledgement is still in flight. Because the CRDT removes by
  /// `(pid, topic, key)` and not by ref, two coexisting refs for one tuple
  /// would make the later, compensating untrack of the older ref remove
  /// the newer entry as well. Superseding here means the older ref is gone
  /// from the ref map by the time that compensation arrives, so it lands
  /// as a harmless no-op.
  SupersedeSameKey(explicit: Option(String))
}

/// The refs a track must remove before joining: none for the public API,
/// and for the runtime the explicit replacement plus every ref still held
/// for the same logical `(pid, topic, key)`, deduplicated.
fn superseded_refs(
  refs: Dict(String, TrackedPresence),
  topic: String,
  key: String,
  pid: String,
  supersede: Supersede,
) -> List(String) {
  case supersede {
    SupersedeNothing -> []
    SupersedeSameKey(explicit) -> {
      let same_key =
        refs
        |> dict.filter(fn(_ref, tracked) {
          tracked.topic == topic
          && tracked.key == key
          && tracked.session_id == pid
        })
        |> dict.keys
      case explicit {
        // An explicit ref the map no longer holds is kept in the list and
        // skipped by `remove_refs`; dropping it here would be equivalent.
        Some(old_ref) ->
          case list.contains(same_key, old_ref) {
            True -> same_key
            False -> [old_ref, ..same_key]
          }
        None -> same_key
      }
    }
  }
}

/// Track one key, superseding previous refs for it (see `Supersede`) in the
/// same turn. Returns the new actor state, the generated ref, and the meta
/// as stored (the caller's meta with `phx_ref` merged in).
fn do_track(
  actor_state: ActorState,
  topic: String,
  key: String,
  pid: String,
  meta: json.Json,
  supersede: Supersede,
) -> #(ActorState, String, json.Json) {
  let ref = generate_ref()
  let stored_meta = meta_with_phx_ref(meta, ref)
  // Superseding removes the old entries and adds the new one before
  // anything is published, so the topic's snapshot moves straight from the
  // old meta to the new one — never through an intermediate state without
  // the key — and one `on_diff` carries the whole leave-plus-join
  // transition.
  let removed =
    remove_refs(
      actor_state.crdt,
      actor_state.refs,
      superseded_refs(actor_state.refs, topic, key, pid, supersede),
    )
  let new_crdt = state.join(removed.crdt, pid, topic, key, stored_meta)
  maybe_invoke_on_diff(
    actor_state.config,
    Diff(
      joins: dict.from_list([
        #(topic, [PresenceEntry(session_id: pid, key: key, meta: stored_meta)]),
      ]),
      leaves: removed.leaves,
    ),
  )
  let new_refs =
    dict.insert(
      removed.refs,
      ref,
      TrackedPresence(topic: topic, key: key, session_id: pid),
    )
  publish_topics(
    actor_state.read_table,
    new_crdt,
    unique_strings([topic, ..removed.topics], set.new(), []),
  )
  #(
    ActorState(..actor_state, crdt: new_crdt, dirty: True, refs: new_refs),
    ref,
    stored_meta,
  )
}

/// Remove every named ref in one turn. Unknown or already-removed refs are
/// skipped; a batch that removes nothing leaves the state untouched and
/// invokes no callback.
fn do_untrack_refs(actor_state: ActorState, refs: List(String)) -> ActorState {
  let removed = remove_refs(actor_state.crdt, actor_state.refs, refs)
  use <- bool.guard(when: removed.topics == [], return: actor_state)
  maybe_invoke_on_diff(
    actor_state.config,
    Diff(joins: dict.new(), leaves: removed.leaves),
  )
  internal.logger("beryl.presence")
  |> log.debug("Presence untracked", [
    #("ref_count", int.to_string(list.length(refs))),
    #("topics", string.join(dict.keys(removed.leaves), ",")),
  ])
  publish_topics(
    actor_state.read_table,
    removed.crdt,
    unique_strings(removed.topics, set.new(), []),
  )
  ActorState(..actor_state, crdt: removed.crdt, dirty: True, refs: removed.refs)
}

fn do_untrack_all(actor_state: ActorState, pid: String) -> ActorState {
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
  // every topic the leave touched (from the pre-mutation diff).
  publish_topics(actor_state.read_table, new_crdt, dict.keys(diff.leaves))
  ActorState(..actor_state, crdt: new_crdt, dirty: True, refs: new_refs)
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
