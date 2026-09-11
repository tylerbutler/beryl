//// Distributed presence tracking with a CRDT
////
//// This module wraps the pure `lattice_presence/presence_state` CRDT in an
//// OTP actor that:
//// - Handles track/update/untrack calls
//// - Publishes an actor-owned ETS read model
//// - Requests snapshots at startup and periodically through PubSub
//// - Receives remote snapshots and merges them internally
//// - Hides unavailable remote replicas without forgetting their causal state
//// - Invokes `on_diff` when local changes or merges produce non-empty diffs
////
//// Each actor owns its local entries. Remote snapshots are accepted only from
//// a live owner answering an outstanding request, never through a relay.
//// Unavailable state is retained for 60 seconds before safe compaction; see
//// `with_pubsub` for the recovery and incarnation rules.
////
//// Presence is independent of the beryl runtime and runs under your
//// application's supervision tree.
////
//// ## Read consistency
////
//// The presence actor is the only writer to a protected ETS read model.
//// It atomically replaces each topic's snapshot after completing a mutation,
//// merge, or prune. Synchronous mutations publish before replying, and
//// runtime mutations acknowledge only after publishing, so a later read
//// observes the completed mutation without waiting on the actor mailbox.
////
//// A read concurrent with a queued or in-progress mutation can observe the
//// previous or new complete snapshot. Reads of separate topics do not form
//// one atomic view. If the actor stops, it also destroys the table, and reads
//// return `Error(Nil)` instead of stale data.
////
//// ## Example
////
//// ```gleam
//// let pubsub_handle = pubsub.start(pubsub.default_config())
//// let config =
////   presence.default_config("node1")
////   |> presence.with_pubsub(pubsub_handle)
////   |> presence.with_broadcast_interval(1500)
//// let #(presence_handle, presence_specification) = presence.child_spec(config)
//// let assert Ok(_root) =
////   static_supervisor.new(static_supervisor.OneForOne)
////   |> static_supervisor.add(presence_specification)
////   |> static_supervisor.start()
//// let ref =
////   presence.track(
////     presence_handle,
////     "room:lobby",
////     "user:1",
////     "socket-1",
////     meta,
////   )
//// let assert Ok(entries) = presence.list(presence_handle, "room:lobby")
//// ```

import beryl/internal
import beryl/log
import beryl/overload
import beryl/pubsub.{type PubSub}
import beryl/telemetry
import beryl/wire
import beryl/work_queue
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lattice_presence/presence_state as state

/// Well-known PubSub topic for presence state replication
const sync_topic = "beryl:presence:sync"

/// PubSub event name for presence sync messages
const sync_event = "presence_sync"

const replica_retention_ms = 60_000

const retirement_check_interval_ms = 1000

@external(erlang, "beryl_ffi", "monotonic_time_ms")
fn monotonic_time_ms() -> Int

/// A running Presence instance.
///
/// This handle is opaque. Callers cannot forge actor subjects or depend on
/// the runtime representation. It contains the actor's stable registered
/// subject and the name of its actor-owned ETS read model.
///
/// ## Node affinity
///
/// The stable registered subject and ETS read model are resolved on the
/// caller's node. Keep a `Presence` handle on the node where its child
/// specification runs. From another BEAM node, synchronous mutations
/// (`track`, `update`, `untrack`, and `untrack_all`) cannot reach the owning
/// actor and panic as unavailable, while `list`, `get_by_key`, and `count`
/// return `Error(Nil)` because the read model is unavailable. Use PubSub
/// replication (`with_pubsub`) to share presence state across nodes instead of
/// moving the handle itself.
pub opaque type Presence {
  Presence(
    subject: Subject(Message),
    read_name: process.Name(Message),
    call_timeout_ms: Int,
  )
}

type State =
  state.State

/// The audience for a presence diff.
pub type DiffScope {
  /// Application mutations and explicitly constructed diffs may be broadcast
  /// to the cluster.
  Cluster
  /// Replication, failure detection, and recovery describe this node's view.
  /// Deliver these diffs only to socket subscribers on the observing node.
  LocalNode
}

/// An opaque diff representing presence joins and leaves grouped by topic.
///
/// beryl passes this value to `Config.on_diff`.
/// `beryl.broadcast_presence_diff` preserves its delivery scope automatically.
pub opaque type Diff {
  Diff(
    joins: Dict(String, List(PresenceEntry)),
    leaves: Dict(String, List(PresenceEntry)),
    scope: DiffScope,
  )
}

/// A presence entry returned from queries and diff accessors.
///
/// This type is transparent. Callers can inspect query results and construct
/// entries for `diff`.
pub type PresenceEntry {
  PresenceEntry(session_id: String, key: String, meta: json.Json)
}

/// Build a presence diff from topic-grouped joins and leaves.
///
/// Most applications receive diffs from `Config.on_diff`. Use this function
/// to construct an application diff with `Cluster` scope for
/// `beryl.broadcast_presence_diff`. Do not rebuild a replica-view diff with
/// this function: that would discard its `LocalNode` scope.
pub fn diff(
  joins joins: List(#(String, List(PresenceEntry))),
  leaves leaves: List(#(String, List(PresenceEntry))),
) -> Diff {
  Diff(
    joins: dict.from_list(joins),
    leaves: dict.from_list(leaves),
    scope: Cluster,
  )
}

/// Return where this diff may be delivered.
///
/// Local application mutations produce `Cluster` diffs. Remote snapshots and
/// replica availability changes produce `LocalNode` diffs, even when one
/// update contains both causal changes and liveness changes. They repair the
/// observing node's view and must not be rebroadcast to other nodes.
///
/// Prefer `beryl.broadcast_presence_diff`, which handles this distinction.
/// Custom publishers must preserve it; the Phoenix JSON payload has no scope.
pub fn diff_scope(diff: Diff) -> DiffScope {
  diff.scope
}

/// List topics touched by this diff.
pub fn diff_topics(diff: Diff) -> List(String) {
  list.append(dict.keys(diff.joins), dict.keys(diff.leaves))
  |> unique_strings(set.new(), [])
}

/// Return presence joins for a topic in this diff.
pub fn diff_joins(diff: Diff, topic: String) -> List(PresenceEntry) {
  dict.get(diff.joins, topic)
  |> result.unwrap([])
}

/// Return presence leaves for a topic in this diff.
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

type VisibleEntry =
  #(String, String, String, json.Json)

fn visible_counts(crdt: State) -> Dict(VisibleEntry, Int) {
  state.online_list(crdt)
  |> list.fold(dict.new(), fn(counts, entry) {
    let count = dict.get(counts, entry) |> result.unwrap(0)
    dict.insert(counts, entry, count + 1)
  })
}

fn added_entries(
  after: Dict(VisibleEntry, Int),
  before: Dict(VisibleEntry, Int),
) -> Dict(String, List(PresenceEntry)) {
  dict.fold(after, dict.new(), fn(grouped, entry, count) {
    let added = count - { dict.get(before, entry) |> result.unwrap(0) }
    use <- bool.guard(when: added <= 0, return: grouped)
    let #(session_id, topic, key, meta) = entry
    let existing = dict.get(grouped, topic) |> result.unwrap([])
    dict.insert(
      grouped,
      topic,
      list.append(
        list.repeat(PresenceEntry(session_id, key, meta), added),
        existing,
      ),
    )
  })
}

/// The CRDT's merge diff includes hidden entries. Compare final visible
/// multisets instead, preserving duplicate non-object metas without phx_ref.
fn visible_diff(before: State, after: State) -> Diff {
  let before = visible_counts(before)
  let after = visible_counts(after)
  Diff(
    joins: added_entries(after, before),
    leaves: added_entries(before, after),
    scope: LocalNode,
  )
}

/// The snapshot request carried over PubSub between presence replicas.
///
/// Version 2 replaces unsolicited state gossip with request/reply snapshots.
/// The version stays in the first tuple field so version 1 peers can reject
/// it before reading the changed fields. The outer PubSub tuple is unchanged.
@internal
pub type SyncPayload {
  SyncPayload(
    version: Int,
    request: Reference,
    reply: Subject(SyncReply),
    request_back: Bool,
  )
}

/// A snapshot answering one outstanding request to a specific group member.
@internal
pub type SyncReply {
  SyncReply(request: Reference, owner: process.Pid, state: state.State)
}

/// Configuration for starting presence.
///
/// Build configurations with `default_config` and the `with_*` functions.
/// beryl can then add options without exposing record fields as public API.
pub opaque type Config {
  Config(
    /// PubSub instance for cross-node replication
    pubsub: Option(PubSub(SyncPayload)),
    /// This node's replica base name. Must identify at most one live node
    /// in the cluster. Each actor start derives a unique incarnation name
    /// from it, so restarting a node never reuses the previous
    /// incarnation's CRDT clocks; state from older incarnations of the
    /// same base is pruned automatically. Two *live* nodes sharing
    /// a base violate the ownership contract; concurrent reuse is unsupported.
    replica: String,
    /// How often to request snapshots for replication (ms). Non-positive
    /// values disable periodic requests, but not the initial exchange or replies.
    broadcast_interval_ms: Int,
    /// Timeout for synchronous presence mutations (ms).
    call_timeout_ms: Int,
    /// Optional callback invoked immediately when a merge produces a non-empty diff.
    /// This ensures no diffs are lost when multiple merges occur in rapid succession.
    /// Runs synchronously on the actor, strictly before the read model is
    /// republished for the topics the diff touches -- see `with_on_diff`.
    on_diff: Option(fn(Diff) -> Nil),
    queue_limits: overload.Limits,
    telemetry: Bool,
  )
}

/// Errors from an update to a tracked presence.
pub type PresenceUpdateError {
  /// The ref is unknown, already removed, or was not returned by `track`.
  UnknownRef(ref: String)
  RequestFailed(overload.CallError)
}

/// Messages that the presence actor handles.
pub opaque type Message {
  WorkAvailable
  WorkRecoveryTick
  Track(
    topic: String,
    key: String,
    session_id: String,
    meta: json.Json,
    reply: fn(String) -> Nil,
  )
  Update(
    ref: String,
    meta: json.Json,
    reply: fn(Result(String, PresenceUpdateError)) -> Nil,
  )
  Untrack(ref: String, reply: fn(Nil) -> Nil)
  UntrackAll(session_id: String, reply: fn(Nil) -> Nil)
  /// Asynchronous track used by the runtime's effect interpreter. The new
  /// entry supersedes every runtime-owned ref this actor still holds for the
  /// same logical `(session_id, topic, key)` — `replace`, when the caller knows the
  /// previous ref, plus any runtime ref the caller has lost track of (an
  /// earlier operation it timed out on, say). Public synchronous refs remain
  /// independently owned. The owner is monitored so all runtime refs for its
  /// session are removed when it exits. All of that happens in actor order, so
  /// cleanup cannot race ahead of an in-flight mutation.
  TrackAsync(
    topic: String,
    key: String,
    session_id: String,
    meta: json.Json,
    replace: Option(String),
    owner: process.Pid,
    tag: String,
    operation_id: Int,
    reply: Subject(MutationAck),
  )
  /// Asynchronous batch untrack by ref, used by the runtime for both the
  /// `PresenceUntrack` effect and topic-close cleanup. Every ref is removed
  /// in one turn, producing one `on_diff` and one read-model publication
  /// per touched topic.
  UntrackAsync(
    refs: List(String),
    tag: String,
    operation_id: Int,
    reply: Subject(MutationAck),
  )
  /// Fire-and-forget runtime-owned socket sweep, used while the runtime is
  /// shutting down and unable to wait for an acknowledgement. Public refs
  /// and refs from replacement socket owners remain independently owned.
  UntrackRuntimeOwner(owner: process.Pid)
  BroadcastTick
  /// Incoming PubSub snapshot request from a remote replica.
  RemoteSync(pubsub_message: pubsub.Message(SyncPayload))
  RemoteSnapshot(reply: SyncReply)
  RemoteReplicaDown(down: process.Down)
  RetirementTick
}

/// Acknowledgement of an asynchronous presence mutation.
///
/// `tag` and `operation_id` are echoed back verbatim from the request so the
/// caller can route the acknowledgement to the right waiter and discard
/// acknowledgements for operations it has already given up on.
@internal
pub type MutationAck {
  MutationAck(tag: String, operation_id: Int, outcome: MutationOutcome)
}

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

type RuntimeOwnerWatch {
  RuntimeOwnerExited
  PresenceExited
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

/// The actor-owned ETS read-model table reference. Opaque phantom type:
/// values are only created and consumed by `beryl_presence_read_ffi`.
type ReadTable

@external(erlang, "beryl_presence_read_ffi", "new_table")
fn ffi_new_read_table(name: process.Name(Message)) -> ReadTable

@external(erlang, "beryl_presence_read_ffi", "put_topic")
fn ffi_put_topic(
  table: ReadTable,
  topic: String,
  count: Int,
  entries: List(PresenceEntry),
) -> Nil

@external(erlang, "beryl_presence_read_ffi", "delete_topic")
fn ffi_delete_topic(table: ReadTable, topic: String) -> Nil

@external(erlang, "beryl_presence_read_ffi", "get_topic")
fn ffi_get_topic(name: process.Name(Message), topic: String) -> TopicLookup

@external(erlang, "beryl_presence_read_ffi", "get_count")
fn ffi_get_count(name: process.Name(Message), topic: String) -> CountLookup

/// Materialize a topic's current entries (and their count) from `crdt` into
/// the read model, or remove its snapshot entirely once it has no entries
/// left, so a missing topic is only ever "no snapshot recorded", never a
/// stale empty leftover.
fn publish_topic(table: ReadTable, crdt: State, topic: String) -> Nil {
  let entries =
    state.get_by_topic(crdt, topic)
    |> list.map(fn(entry) {
      let #(session_id, key, meta) = entry
      PresenceEntry(session_id: session_id, key: key, meta: meta)
    })
  case entries {
    [] -> ffi_delete_topic(table, topic)
    _ -> ffi_put_topic(table, topic, list.length(entries), entries)
  }
}

/// Republish every topic named in `topics` from `crdt`. Used after
/// operations (remote merges, replica pruning) that can touch several
/// topics at once.
fn publish_topics(table: ReadTable, crdt: State, topics: List(String)) -> Nil {
  list.each(topics, fn(topic) { publish_topic(table, crdt, topic) })
}

/// Read a topic's materialized entries directly from the read model.
///
/// Returns `Error(Nil)` if the read model table is unavailable -- either
/// because the presence actor that owns it is no longer running, or because
/// this handle is being used from a process on a different BEAM node than
/// the one the child was started on (see the node affinity note on `Presence`).
fn read_entries(
  presence: Presence,
  topic: String,
) -> Result(List(PresenceEntry), Nil) {
  case ffi_get_topic(presence.read_name, topic) {
    Found(entries) -> Ok(entries)
    NotFound -> Ok([])
    TableGone -> Error(Nil)
  }
}

/// A tracked presence's location within the CRDT, keyed by tracking ref.
type RefOwner {
  PublicOwner
  RuntimeOwner(process.Pid)
}

type TrackedPresence {
  TrackedPresence(
    topic: String,
    key: String,
    session_id: String,
    meta: json.Json,
    tag: state.Tag,
    owner: RefOwner,
  )
}

type PendingSync {
  PendingSync(request: Reference, round: Int, requested_at: Int)
}

type ReplicaAvailability {
  Available(monitor: process.Monitor)
  Unavailable(since: Int)
}

type ReplicaOwner {
  ReplicaOwner(
    replica: String,
    pid: process.Pid,
    availability: ReplicaAvailability,
    confirmed_round: Int,
  )
}

type SyncState {
  SyncState(
    reply: Subject(SyncReply),
    requests: Dict(process.Pid, PendingSync),
    round: Int,
    /// One confirmed incarnation per configured replica base.
    owners: Dict(String, ReplicaOwner),
  )
}

/// Internal actor state
type ActorState {
  ActorState(
    crdt: State,
    config: Config,
    /// The actor's own subject, used by timers and owner monitors.
    self_subject: Option(Subject(Message)),
    sync: Option(SyncState),
    /// Maps each server-generated tracking ref to the presence it created, so
    /// `untrack` can locate the correct CRDT entry to leave. Populated on
    /// `Track` and pruned on `Untrack`/`UntrackAll`.
    refs: Dict(String, TrackedPresence),
    /// Socket actors with runtime-owned presence and a live monitor process.
    runtime_owners: Set(process.Pid),
    /// The ETS table backing the read model that `list`, `get_by_key`, and
    /// `count` read directly. Owned by this actor process; see `publish_topic`.
    read_table: ReadTable,
    inbox: work_queue.Queue(Message),
  )
}

/// Default configuration (no PubSub).
///
/// The repair interval defaults to 1500 ms. Adding `with_pubsub` enables an
/// initial snapshot request and periodic repair, even without local changes.
/// Without PubSub, the interval is unused. A non-positive interval disables
/// periodic requests, but the initial exchange and replies remain enabled.
pub fn default_config(replica: String) -> Config {
  Config(
    pubsub: None,
    replica: replica,
    broadcast_interval_ms: 1500,
    call_timeout_ms: 5000,
    on_diff: None,
    queue_limits: overload.shared_limits(),
    telemetry: False,
  )
}

/// Enable PubSub replication for presence.
///
/// Remote visibility follows monitored actor ownership and the local `pg`
/// membership view. Actor exit, node disconnection, or membership loss hides
/// that replica and emits leaves. Its causal state remains available for repair.
/// A fresh snapshot from the same actor restores its current entries; a
/// replacement actor starts a new incarnation. A partition can therefore hide
/// sessions that remain connected to their local node.
///
/// Each snapshot contains only its sender's authoritative state. A receiver's
/// request order, not a random suffix or message arrival order, determines
/// whether a new incarnation can replace its known owner. Concurrent live
/// actors sharing a replica base in one scope are unsupported.
///
/// A confirmed replacement retires its predecessor. Otherwise, unavailable
/// state remains for 60 seconds, checked every second while the actor runs.
/// Compaction invalidates outstanding requests. A returning actor must answer
/// a new request with its current full local snapshot, so delayed replies and
/// lagging peers cannot reintroduce compacted history. The retention check also
/// runs when periodic snapshot requests are disabled. Actor work can delay it.
pub fn with_pubsub(config: Config, pubsub: PubSub(SyncPayload)) -> Config {
  Config(..config, pubsub: Some(pubsub))
}

/// Bound queued and executing local mutations. Replication is not admitted here.
pub fn with_queue_limits(config: Config, limits: overload.Limits) -> Config {
  Config(..config, queue_limits: limits)
}

/// Emit local mutation queue occupancy and overload events.
pub fn with_telemetry(config: Config) -> Config {
  Config(..config, telemetry: True)
}

/// Set how often presence requests full snapshots from its PubSub peers.
///
/// Requests run at startup and every `interval_ms` thereafter, including when
/// no application state changes. Lost requests or replies are retried on later
/// ticks. The default is 1500 ms; this is a repair cadence, not a convergence
/// deadline. Delivery, membership propagation, and actor work can delay repair.
///
/// A non-positive value disables periodic requests, not the initial request or
/// replies to peers. Without periodic requests, quiet recovery is not guaranteed.
pub fn with_broadcast_interval(config: Config, interval_ms: Int) -> Config {
  Config(..config, broadcast_interval_ms: interval_ms)
}

/// Set the timeout for synchronous presence mutations, in milliseconds.
///
/// This timeout applies to `track`, `update`, `untrack`, and `untrack_all`. These
/// functions panic if the actor does not reply before the timeout. The default
/// is 5000 ms.
pub fn with_call_timeout(config: Config, timeout_ms: Int) -> Config {
  Config(..config, call_timeout_ms: timeout_ms)
}

/// Set the callback for diffs from local changes, remote merges, or replica
/// availability changes.
///
/// Pass the original diff to `beryl.broadcast_presence_diff` to preserve its
/// delivery scope. Application mutations publish cluster-wide at their source.
/// Replication and availability callbacks repair local clients only. A custom
/// publisher must inspect `diff_scope` rather than broadcast encoded JSON
/// unconditionally. A local worker may handle the callback; do not move a
/// `LocalNode` diff to another node for publication.
///
/// The callback runs synchronously on the presence actor, for both local
/// mutations (`track`/`update`/`untrack`/`untrack_all`, and the asynchronous
/// mutations the runtime issues for presence effects) and remote merges,
/// before the affected topics' read-model snapshots are (re)published and
/// before the triggering call replies or the mutation is acknowledged.
/// This ordering is the same for local and remote diffs.
///
/// If the callback reads presence state through the same
/// `Presence` handle (`list`, `get_by_key`, `count`) for a topic this diff
/// changes, it observes the *previous* snapshot. It does not observe the
/// snapshot that the diff will produce. Read the entries and counts you need
/// directly from the `Diff` argument (via
/// `diff_joins`/`diff_leaves`) instead of re-reading through `presence`
/// inside the callback.
///
/// Keep the callback fast and non-blocking. It runs on the actor process.
/// A slow or blocking callback delays that topic's read-model publish,
/// the reply to (or acknowledgement of) the mutating operation, and every
/// other message behind it in the actor's mailbox. Concurrent
/// `list`/`get_by_key`/`count` calls from other processes do not use the
/// mailbox and are not delayed. A socket with an active presence effect waits
/// for the callback. Callers of synchronous mutations also wait for their
/// replies.
pub fn with_on_diff(config: Config, callback: fn(Diff) -> Nil) -> Config {
  Config(..config, on_diff: Some(callback))
}

@internal
pub fn subject(presence: Presence) -> Subject(Message) {
  presence.subject
}

/// Build the supervised presence actor.
///
/// Add the returned child specification to your application's supervisor.
/// The returned handle is name-backed and works again after a supervised
/// restart. A restart resets the in-memory presence entries and tracking refs.
pub fn child_spec(
  config: Config,
) -> #(Presence, supervision.ChildSpecification(Subject(Message))) {
  let name = process.new_name("beryl_presence")
  #(
    from_name(name, config.call_timeout_ms),
    supervision.worker(fn() { start_named(config, name) }),
  )
}

@internal
pub fn start(config: Config) -> Result(Presence, actor.StartError) {
  let name = process.new_name("beryl_presence")
  start_named(config, name)
  |> result.map(fn(_started) { from_name(name, config.call_timeout_ms) })
}

/// Read mutation and reserved-cleanup accounting without waiting for the actor.
pub fn queue_snapshot(
  presence: Presence,
) -> Result(overload.Occupancy, overload.AdmissionError) {
  use queue <- result.try(work_queue.lookup(presence.read_name))
  work_queue.snapshot(queue)
}

fn from_name(name: process.Name(Message), call_timeout_ms: Int) -> Presence {
  Presence(
    subject: process.named_subject(name),
    read_name: name,
    call_timeout_ms: call_timeout_ms,
  )
}

fn start_named(
  config: Config,
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  build_presence(config, name)
  |> actor.named(name)
  |> actor.start
}

fn build_presence(
  config: Config,
  read_name: process.Name(Message),
) -> actor.Builder(ActorState, Message, Subject(Message)) {
  // Each actor start is a fresh CRDT incarnation. Reusing the bare replica
  // name after a restart would reset its clocks while peers still remember
  // the old ones: new joins would be silently filtered as already-seen,
  // and the previous incarnation's entries would resurrect via merges.
  // The library mints an identity that is unique per start and keeps the
  // configured name recoverable. Receiver-issued requests establish
  // incarnation freshness; the identity itself does not order actor starts.
  let crdt = state.new_incarnation(config.replica)

  actor.new_with_initialiser(5000, fn(subject) {
    // Created here, in the actor process itself, so the read model's
    // lifetime is tied to the actor: it is destroyed automatically if this
    // process stops or crashes, matching the "actor unavailable" failure
    // mode readers already get from a dead actor.
    let read_table = ffi_new_read_table(read_name)
    let inbox =
      work_queue.new(
        config.queue_limits,
        overload.PresenceQueue,
        config.telemetry,
        fn() { process.send(subject, WorkAvailable) },
      )
    work_queue.name(inbox, read_name)
    schedule_work_recovery(subject)
    let initial =
      ActorState(
        crdt: crdt,
        config: config,
        self_subject: Some(subject),
        sync: None,
        refs: dict.new(),
        runtime_owners: set.new(),
        read_table: read_table,
        inbox: inbox,
      )

    case config.pubsub {
      Some(pubsub_instance) -> {
        // Subscribe to the well-known sync topic for replication
        let subscriber = pubsub.subscriber(pubsub_instance)
        pubsub.join(subscriber, sync_topic)
        let reply = process.new_subject()
        let initial =
          ActorState(
            ..initial,
            sync: Some(SyncState(
              reply: reply,
              requests: dict.new(),
              round: 0,
              owners: dict.new(),
            )),
          )
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
          |> process.select_map(reply, RemoteSnapshot)
          |> process.select_monitors(RemoteReplicaDown)
          |> pubsub.selecting(subscriber, RemoteSync)

        process.send(subject, BroadcastTick)
        schedule_retirement_tick(subject)

        actor.initialised(initial)
        |> actor.selecting(selector)
        |> actor.returning(subject)
        |> Ok
      }
      None -> {
        actor.initialised(initial)
        |> actor.returning(subject)
        |> Ok
      }
    }
  })
  |> actor.on_message(handle_message)
}

/// Keep one outstanding request per member. Retry its ref until a reply arrives
/// so a slow peer need not finish within a single repair interval.
fn request_snapshots(
  actor_state: ActorState,
  pubsub_instance: PubSub(SyncPayload),
) -> ActorState {
  let members =
    pubsub.subscribers(pubsub_instance, sync_topic)
    |> list.filter(fn(member) { member != process.self() })
    |> set.from_list
  let actor_state = reconcile_membership(actor_state, members)
  case actor_state.sync {
    None -> actor_state
    Some(sync) -> {
      let sync =
        SyncState(
          ..sync,
          requests: dict.filter(sync.requests, fn(member, _) {
            set.contains(members, member)
          }),
          round: sync.round + 1,
        )
      let sync =
        set.fold(members, sync, fn(sync, member) {
          request_snapshot(sync, pubsub_instance, member, True)
        })
      ActorState(..actor_state, sync: Some(sync))
    }
  }
}

fn reconcile_membership(
  actor_state: ActorState,
  members: Set(process.Pid),
) -> ActorState {
  case actor_state.sync {
    None -> actor_state
    Some(sync) ->
      dict.fold(sync.owners, actor_state, fn(actor_state, base, owner) {
        case set.contains(members, owner.pid) {
          True -> actor_state
          False -> hide_replica(actor_state, base)
        }
      })
  }
}

fn hide_replica(actor_state: ActorState, base: String) -> ActorState {
  case actor_state.sync {
    None -> actor_state
    Some(sync) ->
      case dict.get(sync.owners, base) {
        Error(Nil) | Ok(ReplicaOwner(_, _, Unavailable(_), _)) -> actor_state
        Ok(ReplicaOwner(replica, pid, Available(monitor), round)) -> {
          process.demonitor_process(monitor)
          let #(crdt, _diff) = state.replica_down(actor_state.crdt, replica)
          commit_replication(
            ActorState(
              ..actor_state,
              sync: Some(
                SyncState(
                  ..sync,
                  requests: dict.delete(sync.requests, pid),
                  owners: dict.insert(
                    sync.owners,
                    base,
                    ReplicaOwner(
                      replica,
                      pid,
                      Unavailable(monotonic_time_ms()),
                      round,
                    ),
                  ),
                ),
              ),
            ),
            crdt,
          )
        }
      }
  }
}

fn handle_replica_down(
  actor_state: ActorState,
  down: process.Down,
) -> ActorState {
  case actor_state.sync, down {
    Some(sync), process.ProcessDown(monitor, pid, _) ->
      dict.fold(sync.owners, actor_state, fn(actor_state, base, owner) {
        case owner.pid == pid && owner.availability == Available(monitor) {
          True -> hide_replica(actor_state, base)
          False -> actor_state
        }
      })
    None, _ | _, process.PortDown(_, _, _) -> actor_state
  }
}

fn watch_replica(
  actor_state: ActorState,
  replica: String,
  pid: process.Pid,
  round: Int,
) -> ActorState {
  case actor_state.sync {
    None -> actor_state
    Some(sync) -> {
      let base = state.base_replica(replica)
      let previous = dict.get(sync.owners, base)
      let monitor = case previous {
        Ok(ReplicaOwner(_, old_pid, Available(monitor), _)) if old_pid == pid ->
          monitor
        Ok(ReplicaOwner(_, _, Available(monitor), _)) -> {
          process.demonitor_process(monitor)
          process.monitor(pid)
        }
        Ok(ReplicaOwner(_, _, Unavailable(_), _)) | Error(Nil) ->
          process.monitor(pid)
      }
      let requests = case previous {
        Ok(previous) if previous.pid != pid ->
          dict.delete(sync.requests, previous.pid)
        Ok(_) | Error(Nil) -> sync.requests
      }
      ActorState(
        ..actor_state,
        sync: Some(
          SyncState(
            ..sync,
            requests: requests,
            owners: dict.insert(
              sync.owners,
              base,
              ReplicaOwner(replica, pid, Available(monitor), round),
            ),
          ),
        ),
      )
    }
  }
}

fn schedule_retirement_tick(subject: Subject(Message)) -> Nil {
  let _timer =
    process.send_after(subject, retirement_check_interval_ms, RetirementTick)
  Nil
}

fn retire_unavailable(actor_state: ActorState) -> ActorState {
  let members = case actor_state.config.pubsub {
    Some(pubsub_instance) ->
      pubsub.subscribers(pubsub_instance, sync_topic) |> set.from_list
    None -> set.new()
  }
  let actor_state = reconcile_membership(actor_state, members)
  case actor_state.sync {
    None -> actor_state
    Some(sync) -> {
      let now = monotonic_time_ms()
      let sync =
        SyncState(
          ..sync,
          requests: dict.filter(sync.requests, fn(pid, pending) {
            set.contains(members, pid)
            || now - pending.requested_at < replica_retention_ms
          }),
        )
      let actor_state = ActorState(..actor_state, sync: Some(sync))
      let retired =
        dict.filter(sync.owners, fn(_base, owner) {
          case owner.availability {
            Available(_) -> False
            Unavailable(since) -> now - since >= replica_retention_ms
          }
        })
      use <- bool.guard(when: dict.is_empty(retired), return: actor_state)
      let crdt =
        dict.fold(retired, actor_state.crdt, fn(crdt, _base, owner) {
          compact_replica(crdt, owner.replica)
        })
      let owners =
        dict.fold(retired, sync.owners, fn(owners, base, _) {
          dict.delete(owners, base)
        })
      // Dropping a base's freshness record is safe only after revoking every
      // pre-compaction reply, including requests to unconfirmed old owners.
      ActorState(
        ..actor_state,
        crdt: crdt,
        sync: Some(SyncState(..sync, owners: owners, requests: dict.new())),
      )
    }
  }
}

fn request_snapshot(
  sync: SyncState,
  pubsub_instance: PubSub(SyncPayload),
  member: process.Pid,
  request_back: Bool,
) -> SyncState {
  let round = sync.round + 1
  let pending =
    dict.get(sync.requests, member)
    |> result.lazy_unwrap(fn() {
      PendingSync(reference.new(), round, monotonic_time_ms())
    })
  pubsub.send_to(
    pubsub_instance,
    member,
    sync_topic,
    sync_event,
    SyncPayload(
      version: 2,
      request: pending.request,
      reply: sync.reply,
      request_back: request_back,
    ),
  )
  SyncState(
    ..sync,
    requests: dict.insert(sync.requests, member, pending),
    round: round,
  )
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

fn compact_replica(crdt: State, replica: String) -> State {
  let #(crdt, _diff) = state.replica_down(crdt, replica)
  state.remove_down_replica(crdt, replica)
}

/// Reduce a state to the data its own replica owns.
///
/// beryl replicates one full state per owner. The dependency's lifecycle API
/// keeps a high-water clock for every replica it removes, which is correct for
/// local state but wrong to relay: a receiver that adopted a peer's clocks for
/// a third replica would treat that replica's later entries as already seen.
@external(erlang, "beryl_presence_state_ffi", "owner_snapshot")
fn owner_snapshot(crdt: State) -> State

/// Merge the server-generated tracking ref into the tracked meta as
/// `phx_ref`, matching Phoenix behaviour. Phoenix client `Presence` helpers
/// identify individual metas by `phx_ref` when applying diffs; without it a
/// single leave would remove every meta stored under the same key. Any
/// client-supplied `phx_ref` is replaced. Non-object metas are stored
/// unchanged (Phoenix requires object metas for its Presence helpers).
fn meta_with_phx_ref(meta: json.Json, ref: String) -> json.Json {
  case
    json.parse(
      from: json.to_string(meta),
      using: decode.dict(decode.string, decode.dynamic),
    )
  {
    // nolint: thrown_away_error -- a non-object meta is stored unchanged by design (see doc comment); the parse error carries no other information
    Error(_) -> meta
    Ok(fields) ->
      fields
      |> dict.delete("phx_ref")
      |> dict.to_list
      |> list.try_map(fn(field) {
        wire.dynamic_to_json(field.1)
        |> result.map(fn(value) { #(field.0, value) })
      })
      |> result.map(fn(converted) {
        converted
        |> list.append([#("phx_ref", json.string(ref))])
        |> json.object
      })
      |> result.unwrap(meta)
  }
}

/// Track a presence in a topic.
///
/// `session_id` identifies the session, such as a socket, that owns this
/// presence. `untrack_all` matches this value when the session disconnects.
///
/// Returns a server-generated tracking ref. It is an opaque, unique handle for
/// this presence. Pass it to `untrack` to remove this entry. The ref is not
/// the session ID. The presence actor creates it, and it is meaningful only
/// to that actor. The ref is also merged into object metas as `phx_ref` for
/// Phoenix client compatibility.
///
/// Returns a typed call error on admission failure, owner exit, or timeout
/// (5 seconds by default). A timeout cancels pending work, but a running
/// mutation may still complete.
pub fn track(
  presence: Presence,
  topic: String,
  key: String,
  session_id: String,
  meta: json.Json,
) -> Result(String, overload.CallError) {
  call(presence, fn(reply) { Track(topic, key, session_id, meta, reply) })
}

/// Replace the meta of a presence created by `track`.
///
/// One diff contains the old ref's leave and the new ref's join. Subscribers
/// do not observe an intermediate state without the presence key. Other
/// tracked refs for the same key do not change.
///
/// Returns the replacement ref, which must be used for subsequent `update`
/// or `untrack` calls. Returns `Error(UnknownRef(ref))` when `ref` is
/// unknown, already removed, or belongs to the internal runtime.
///
/// `RequestFailed` wraps admission, owner-exit, and timeout errors. A timeout
/// cancels pending work, but a running mutation may still complete.
pub fn update(
  presence: Presence,
  ref: String,
  meta: json.Json,
) -> Result(String, PresenceUpdateError) {
  call(presence, fn(reply) { Update(ref, meta, reply) })
  |> result.map_error(RequestFailed)
  |> result.flatten
}

/// Untrack a specific presence using the ref returned by `track`.
///
/// Removing an unknown or already-removed ref is a harmless no-op.
///
/// Returns a typed call error on admission failure, owner exit, or timeout.
/// A timeout cancels pending work, but a running mutation may still complete.
pub fn untrack(
  presence: Presence,
  ref: String,
) -> Result(Nil, overload.CallError) {
  call(presence, fn(reply) { Untrack(ref, reply) })
}

/// Untrack all presences for a session, such as when a socket disconnects.
///
/// Returns a typed call error on admission failure, owner exit, or timeout.
/// A timeout cancels pending work, but a running mutation may still complete.
pub fn untrack_all(
  presence: Presence,
  session_id: String,
) -> Result(Nil, overload.CallError) {
  call(presence, fn(reply) { UntrackAll(session_id, reply) })
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

/// Track a presence asynchronously. The new entry supersedes, atomically in
/// the same actor turn, both `replace` (a runtime ref from a previous track
/// of this key, when the caller still knows it) and any other runtime-owned
/// ref for the same `(session_id, topic, key)`. Public synchronous refs for
/// that tuple remain independent. The owner is monitored and all its runtime
/// refs are removed after it exits. The acknowledgement carries the generated
/// ref and the stored meta.
@internal
pub fn track_async(
  presence presence: Presence,
  topic topic: String,
  key key: String,
  session_id session_id: String,
  meta meta: json.Json,
  replace replace: Option(String),
  owner owner: process.Pid,
  tag tag: String,
  operation_id operation_id: Int,
  reply reply: Subject(MutationAck),
) -> Result(Nil, overload.AdmissionError) {
  use queue <- result.try(work_queue.lookup(presence.read_name))
  work_queue.publish_with_cleanup(
    queue,
    owner,
    TrackAsync(
      topic: topic,
      key: key,
      session_id: session_id,
      meta: meta,
      replace: replace,
      owner: owner,
      tag: tag,
      operation_id: operation_id,
      reply: reply,
    ),
    UntrackRuntimeOwner(owner),
  )
  |> result.map(fn(_) { Nil })
}

/// Untrack a batch of refs asynchronously. Unknown or already-removed refs
/// are skipped; the whole batch is one actor turn, one `on_diff`, and one
/// read-model publication per touched topic.
@internal
pub fn untrack_async(
  presence presence: Presence,
  refs refs: List(String),
  tag tag: String,
  operation_id operation_id: Int,
  reply reply: Subject(MutationAck),
) -> Result(Nil, overload.AdmissionError) {
  use queue <- result.try(work_queue.lookup(presence.read_name))
  work_queue.send(
    queue,
    UntrackAsync(refs: refs, tag: tag, operation_id: operation_id, reply: reply),
  )
}

/// Sweep every presence a socket owner still holds, without
/// acknowledgement. Used while the runtime is shutting down, when it can no
/// longer wait. Public refs and replacement socket owners are untouched.
@internal
pub fn untrack_runtime_owner_async(
  presence: Presence,
  owner: process.Pid,
) -> Nil {
  let result = {
    use queue <- result.try(work_queue.lookup(presence.read_name))
    work_queue.activate_cleanup(queue, owner)
  }
  case result {
    Ok(Nil) -> Nil
    Error(error) ->
      log.warn(
        internal.logger("beryl.presence"),
        "Presence cleanup owner unavailable",
        [
          #("reason", overload.describe(error)),
        ],
      )
  }
}

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
/// This function reads the actor-owned read model directly. The read model is
/// an ETS snapshot created after each mutation, merge, or prune. This function
/// does not wait on the actor mailbox. See the module's **Read consistency**
/// section for ordering guarantees.
///
/// Returns `Error(Nil)` when the presence read model is unavailable. This can
/// occur when the presence actor is not running or when this handle is used
/// from a process on another BEAM node than the one it was started on (see
/// the node affinity note on `Presence`).
pub fn list(
  presence: Presence,
  topic: String,
) -> Result(List(PresenceEntry), Nil) {
  read_entries(presence, topic)
}

/// Get presences for a specific key within a topic.
///
/// This function reads the actor-owned read model directly. The read model is
/// an ETS snapshot created after each mutation, merge, or prune. This function
/// does not wait on the actor mailbox. See the module's **Read consistency**
/// section for ordering guarantees.
///
/// Returns `Error(Nil)` when the presence read model is unavailable. This can
/// occur when the presence actor is not running or when this handle is used
/// from a process on another BEAM node than the one it was started on (see
/// the node affinity note on `Presence`).
pub fn get_by_key(
  presence: Presence,
  topic: String,
  key: String,
) -> Result(List(#(String, json.Json)), Nil) {
  read_entries(presence, topic)
  |> result.map(fn(entries) {
    entries
    |> list.filter(fn(entry) { entry.key == key })
    |> list.map(fn(entry) { #(entry.session_id, entry.meta) })
  })
}

/// Count presences in a topic.
///
/// This is equivalent to `list(presence, topic) |> list.length`, but O(1). It
/// reads the materialized count directly from the read model via
/// `ets:lookup_element/4` instead of building (and copying) the entry list
/// just to measure it.
///
/// This function reads the actor-owned read model directly. The read model is
/// an ETS snapshot created after each mutation, merge, or prune. This function
/// does not wait on the actor mailbox. See the module's **Read consistency**
/// section for ordering guarantees.
///
/// Returns `Error(Nil)` when the presence read model is unavailable. This can
/// occur when the presence actor is not running or when this handle is used
/// from a process on another BEAM node than the one it was started on (see
/// the node affinity note on `Presence`).
pub fn count(presence: Presence, topic: String) -> Result(Int, Nil) {
  case ffi_get_count(presence.read_name, topic) {
    CountFound(count) -> Ok(count)
    CountTableGone -> Error(Nil)
  }
}

// ── Actor loop ──────────────────────────────────────────────────────────────

fn call(
  presence: Presence,
  request: fn(fn(reply) -> Nil) -> Message,
) -> Result(reply, overload.CallError) {
  use queue <- result.try(
    work_queue.lookup(presence.read_name)
    |> result.map_error(overload.AdmissionRejected),
  )
  work_queue.call(queue, presence.call_timeout_ms, request)
}

fn schedule_work_recovery(subject: Subject(Message)) -> Nil {
  let _timer = process.send_after(subject, 100, WorkRecoveryTick)
  Nil
}

fn handle_available_work(state: ActorState) -> actor.Next(ActorState, Message) {
  case work_queue.take(state.inbox) {
    Error(Nil) -> actor.continue(state)
    Ok(#(reservation, message)) -> {
      case state.self_subject {
        Some(subject) -> process.send(subject, WorkAvailable)
        None -> Nil
      }
      let next = handle_message(state, message)
      work_queue.release(state.inbox, reservation)
      next
    }
  }
}

fn handle_message(
  actor_state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  let logger = internal.logger("beryl.presence")
  case message {
    WorkAvailable -> handle_available_work(actor_state)
    WorkRecoveryTick -> {
      case actor_state.self_subject {
        Some(subject) -> schedule_work_recovery(subject)
        None -> Nil
      }
      handle_available_work(actor_state)
    }
    Track(topic, key, session_id, meta, reply) -> {
      use #(new_state, ref, _meta) <- continue_with_track(
        actor_state,
        do_track(actor_state, topic, key, session_id, meta, SupersedeNothing),
      )
      log_tracked(logger, topic, key, session_id, ref)
      // The read model was published inside `do_track`, before this reply,
      // so a `track(); list()` caller always observes the entry it just
      // tracked.
      reply(ref)
      actor.continue(new_state)
    }

    Update(ref, meta, reply) -> {
      case dict.get(actor_state.refs, ref) {
        Ok(TrackedPresence(topic, key, session_id, _, _, PublicOwner)) -> {
          use #(new_state, new_ref, _meta) <- continue_with_track(
            actor_state,
            do_track(
              actor_state,
              topic,
              key,
              session_id,
              meta,
              SupersedePublicRef(ref),
            ),
          )
          log_tracked(logger, topic, key, session_id, new_ref)
          reply(Ok(new_ref))
          actor.continue(new_state)
        }
        Ok(TrackedPresence(_, _, _, _, _, RuntimeOwner(_))) | Error(Nil) -> {
          reply(Error(UnknownRef(ref)))
          actor.continue(actor_state)
        }
      }
    }

    TrackAsync(
      topic,
      key,
      session_id,
      meta,
      replace,
      owner,
      tag,
      operation_id,
      reply,
    ) ->
      case process.is_alive(owner) {
        False ->
          handle_dead_track_owner(
            actor_state,
            owner,
            tag,
            operation_id,
            reply,
            logger,
          )
        True -> {
          let actor_state = monitor_runtime_owner(actor_state, owner)
          use #(new_state, ref, stored_meta) <- continue_with_track(
            actor_state,
            do_track(
              actor_state,
              topic,
              key,
              session_id,
              meta,
              SupersedeSameKey(explicit: replace, owner: owner),
            ),
          )
          log_tracked(logger, topic, key, session_id, ref)
          process.send(
            reply,
            MutationAck(tag, operation_id, Tracked(ref, stored_meta)),
          )
          actor.continue(new_state)
        }
      }

    Untrack(ref, reply) -> {
      let new_state = do_untrack_refs(actor_state, [ref])
      reply(Nil)
      actor.continue(new_state)
    }

    UntrackAsync(refs, tag, operation_id, reply) -> {
      let new_state = do_untrack_refs(actor_state, refs)
      process.send(reply, MutationAck(tag, operation_id, Untracked))
      actor.continue(new_state)
    }

    UntrackAll(session_id, reply) -> {
      let new_state = do_untrack_all(actor_state, session_id)
      reply(Nil)
      actor.continue(new_state)
    }

    UntrackRuntimeOwner(owner) ->
      actor.continue(
        do_untrack_runtime_owner(actor_state, owner)
        |> fn(state) {
          ActorState(
            ..state,
            runtime_owners: set.delete(state.runtime_owners, owner),
          )
        },
      )

    BroadcastTick -> {
      case actor_state.config.pubsub, actor_state.self_subject {
        Some(pubsub_instance), Some(subject) -> {
          let new_state = request_snapshots(actor_state, pubsub_instance)
          schedule_broadcast_tick(
            subject,
            actor_state.config.broadcast_interval_ms,
          )
          actor.continue(new_state)
        }
        Some(_), None | None, Some(_) | None, None ->
          actor.continue(actor_state)
      }
    }

    RemoteSync(pubsub_message) -> {
      // Only process presence sync messages on the expected topic/event
      case
        pubsub_message.topic == sync_topic && pubsub_message.event == sync_event
      {
        False -> actor.continue(actor_state)
        True -> handle_sync_payload(actor_state, pubsub_message)
      }
    }

    RemoteSnapshot(reply) -> handle_snapshot(actor_state, reply)
    RemoteReplicaDown(down) ->
      actor.continue(handle_replica_down(actor_state, down))
    RetirementTick -> {
      case actor_state.self_subject {
        Some(subject) -> schedule_retirement_tick(subject)
        None -> Nil
      }
      actor.continue(retire_unavailable(actor_state))
    }
  }
}

fn handle_dead_track_owner(
  actor_state: ActorState,
  owner: process.Pid,
  tag: String,
  operation_id: Int,
  reply: Subject(MutationAck),
  logger: log.Logger,
) -> actor.Next(ActorState, Message) {
  let actor_state = case work_queue.activate_cleanup(actor_state.inbox, owner) {
    Ok(Nil) -> actor_state
    Error(error) -> {
      log.warn(logger, "Presence cleanup activation failed", [
        #("reason", overload.describe(error)),
      ])
      // This actor owns the state, so direct cleanup is the safe fallback
      // when its queue cannot schedule the obligation.
      do_untrack_runtime_owner(actor_state, owner)
    }
  }
  process.send(reply, MutationAck(tag, operation_id, Untracked))
  actor.continue(actor_state)
}

fn continue_with_track(
  actor_state: ActorState,
  tracked: Result(value, Nil),
  next: fn(value) -> actor.Next(ActorState, Message),
) -> actor.Next(ActorState, Message) {
  case tracked {
    Ok(value) -> next(value)
    Error(Nil) -> actor.continue(actor_state)
  }
}

fn monitor_runtime_owner(
  actor_state: ActorState,
  owner: process.Pid,
) -> ActorState {
  use <- bool.guard(
    when: set.contains(actor_state.runtime_owners, owner),
    return: actor_state,
  )
  let inbox = actor_state.inbox
  let presence_actor = process.self()
  let _watcher =
    process.spawn_unlinked(fn() {
      let owner_monitor = process.monitor(owner)
      let presence_monitor = process.monitor(presence_actor)
      let exited =
        process.new_selector()
        |> process.select_specific_monitor(owner_monitor, fn(_) {
          RuntimeOwnerExited
        })
        |> process.select_specific_monitor(presence_monitor, fn(_) {
          PresenceExited
        })
        |> process.selector_receive_forever
      case exited {
        RuntimeOwnerExited -> {
          // The obligation was reserved with the track, so saturation cannot
          // prevent cleanup or add an unaccounted message to the actor mailbox.
          case work_queue.activate_cleanup(inbox, owner) {
            Ok(Nil) | Error(overload.Unavailable) -> Nil
            Error(error) ->
              log.warn(
                internal.logger("beryl.presence"),
                "Presence owner cleanup failed",
                [#("reason", overload.describe(error))],
              )
          }
        }
        PresenceExited -> Nil
      }
    })
  ActorState(
    ..actor_state,
    runtime_owners: set.insert(actor_state.runtime_owners, owner),
  )
}

fn log_tracked(
  logger: log.Logger,
  topic: String,
  key: String,
  session_id: String,
  ref: String,
) -> Nil {
  logger
  |> log.debug("Presence tracked", [
    #("topic", topic),
    #("key", key),
    #("session_id", session_id),
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

@external(erlang, "beryl_presence_state_ffi", "remove_tag")
fn remove_tag(crdt: State, tag: state.Tag) -> #(State, Bool)

fn remove_refs(
  crdt: State,
  refs: Dict(String, TrackedPresence),
  removing: List(String),
) -> RemovedRefs {
  list.fold(
    removing,
    RemovedRefs(crdt: crdt, leaves: dict.new(), refs: refs, topics: []),
    fn(removed_refs, ref) {
      case dict.get(removed_refs.refs, ref) {
        Error(Nil) -> removed_refs
        Ok(TrackedPresence(topic, key, session_id, meta, tag, _owner)) -> {
          let #(crdt, removed) = remove_tag(removed_refs.crdt, tag)
          let existing =
            dict.get(removed_refs.leaves, topic)
            |> result.unwrap([])
          RemovedRefs(
            crdt: crdt,
            leaves: case removed {
              False -> removed_refs.leaves
              True ->
                dict.insert(
                  removed_refs.leaves,
                  topic,
                  list.append(existing, [
                    PresenceEntry(session_id: session_id, key: key, meta: meta),
                  ]),
                )
            },
            refs: dict.delete(removed_refs.refs, ref),
            topics: case removed {
              True -> [topic, ..removed_refs.topics]
              False -> removed_refs.topics
            },
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
  /// The public synchronous `update`: supersede exactly the ref supplied by
  /// its owner, leaving every other public ref for the same key unchanged.
  SupersedePublicRef(String)
  /// The runtime's asynchronous track: supersede `explicit` (the previous
  /// runtime ref, when the caller still knows it) and every other
  /// runtime-owned ref this actor holds for the same `(session_id, topic, key)`.
  ///
  /// The sweep is what keeps runtime-owned presence single-valued when the
  /// caller has lost a ref — an operation it timed out on and gave up,
  /// whose acknowledgement is still in flight. Public refs are deliberately
  /// excluded: exact tag removal keeps their independently owned entries
  /// safe from runtime replacement and compensation.
  SupersedeSameKey(explicit: Option(String), owner: process.Pid)
}

/// The refs a track must remove before joining: none for the public API,
/// and for the runtime the explicit replacement plus every runtime-owned ref
/// still held for the same logical `(session_id, topic, key)`, deduplicated.
fn superseded_refs(
  refs: Dict(String, TrackedPresence),
  topic: String,
  key: String,
  session_id: String,
  supersede: Supersede,
) -> List(String) {
  case supersede {
    SupersedeNothing -> []
    SupersedePublicRef(ref) -> [ref]
    SupersedeSameKey(explicit:, owner: _) -> {
      let same_key =
        refs
        |> dict.filter(fn(_ref, tracked) {
          tracked.topic == topic
          && tracked.key == key
          && tracked.session_id == session_id
          && case tracked.owner {
            RuntimeOwner(_) -> True
            PublicOwner -> False
          }
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
/// as stored (the caller's meta with `phx_ref` merged in). Returns an error
/// if the CRDT does not expose the local clock that `state.join` must create.
fn do_track(
  actor_state: ActorState,
  topic: String,
  key: String,
  session_id: String,
  meta: json.Json,
  supersede: Supersede,
) -> Result(#(ActorState, String, json.Json), Nil) {
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
      superseded_refs(actor_state.refs, topic, key, session_id, supersede),
    )
  let new_crdt = state.join(removed.crdt, session_id, topic, key, stored_meta)
  let owner = case supersede {
    SupersedeNothing | SupersedePublicRef(_) -> PublicOwner
    SupersedeSameKey(owner:, ..) -> RuntimeOwner(owner)
  }
  let replica = state.replica(new_crdt)
  // state.join inserts this clock. Keep the lookup fallible so a dependency
  // contract regression rejects the mutation instead of crashing the library.
  use clock <- result.try(
    dict.get(state.compacted_clocks(new_crdt), replica)
    |> result.map_error(fn(error) {
      log.error(internal.logger("beryl.presence"), "Local CRDT clock missing", [
        #("replica", replica),
      ])
      error
    }),
  )
  maybe_invoke_on_diff(
    actor_state.config,
    Diff(
      joins: dict.from_list([
        #(topic, [
          PresenceEntry(session_id: session_id, key: key, meta: stored_meta),
        ]),
      ]),
      leaves: removed.leaves,
      scope: Cluster,
    ),
  )
  let new_refs =
    dict.insert(
      removed.refs,
      ref,
      TrackedPresence(
        topic: topic,
        key: key,
        session_id: session_id,
        meta: stored_meta,
        tag: state.Tag(replica: replica, clock: clock),
        owner: owner,
      ),
    )
  publish_topics(
    actor_state.read_table,
    new_crdt,
    unique_strings([topic, ..removed.topics], set.new(), []),
  )
  Ok(#(
    ActorState(..actor_state, crdt: new_crdt, refs: new_refs),
    ref,
    stored_meta,
  ))
}

/// Remove every named ref in one turn. Unknown or already-removed refs are
/// skipped; a batch that removes no live CRDT entry invokes no callback, but
/// still prunes any dangling refs it named.
fn do_untrack_refs(actor_state: ActorState, refs: List(String)) -> ActorState {
  let removed = remove_refs(actor_state.crdt, actor_state.refs, refs)
  use <- bool.guard(
    when: removed.topics == [],
    return: ActorState(..actor_state, refs: removed.refs),
  )
  maybe_invoke_on_diff(
    actor_state.config,
    Diff(joins: dict.new(), leaves: removed.leaves, scope: Cluster),
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
  ActorState(..actor_state, crdt: removed.crdt, refs: removed.refs)
}

fn do_untrack_all(actor_state: ActorState, session_id: String) -> ActorState {
  let diff = leave_all_diff(actor_state.crdt, session_id)
  let new_crdt = state.leave_by_pid(actor_state.crdt, session_id)
  maybe_invoke_on_diff(actor_state.config, diff)
  // Drop any refs that pointed at the removed session so they cannot leak
  // or later leave presences they no longer own.
  let new_refs =
    dict.filter(actor_state.refs, fn(_ref, tracked) {
      tracked.session_id != session_id
    })
  // A single session can hold presences in several topics; republish
  // every topic the leave touched (from the pre-mutation diff).
  publish_topics(actor_state.read_table, new_crdt, dict.keys(diff.leaves))
  ActorState(..actor_state, crdt: new_crdt, refs: new_refs)
}

fn do_untrack_runtime_owner(
  actor_state: ActorState,
  owner: process.Pid,
) -> ActorState {
  actor_state.refs
  |> dict.filter(fn(_ref, tracked) { tracked.owner == RuntimeOwner(owner) })
  |> dict.keys
  |> do_untrack_refs(actor_state, _)
}

fn leave_all_diff(crdt: State, session_id: String) -> Diff {
  let leaves =
    state.online_list(crdt)
    |> list.filter(fn(entry) { entry.0 == session_id })
    |> list.fold(dict.new(), fn(grouped, entry) {
      let #(_, topic, key, meta) = entry
      let existing =
        dict.get(grouped, topic)
        |> result.unwrap([])
      dict.insert(grouped, topic, [
        PresenceEntry(session_id: session_id, key: key, meta: meta),
        ..existing
      ])
    })

  Diff(joins: dict.new(), leaves: leaves, scope: Cluster)
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

/// Check the envelope version before accessing its version-specific fields.
fn handle_sync_payload(
  actor_state: ActorState,
  message: pubsub.Message(SyncPayload),
) -> actor.Next(ActorState, Message) {
  let payload = message.payload
  case payload.version {
    2 -> {
      process.send(
        payload.reply,
        SyncReply(
          request: payload.request,
          owner: process.self(),
          state: owner_snapshot(actor_state.crdt),
        ),
      )
      case payload.request_back {
        True -> actor.continue(request_snapshot_back(actor_state, message.from))
        False -> actor.continue(actor_state)
      }
    }
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

/// One reciprocal request keeps replicas with periodic repair disabled able to
/// receive updates. Reciprocal requests never trigger another request back.
fn request_snapshot_back(
  actor_state: ActorState,
  from: pubsub.PubSubFrom,
) -> ActorState {
  case actor_state.config.pubsub, actor_state.sync, from {
    Some(pubsub_instance), Some(sync), pubsub.FromPid(owner) -> {
      let members = pubsub.subscribers(pubsub_instance, sync_topic)
      case owner != process.self() && list.contains(members, owner) {
        True ->
          ActorState(
            ..actor_state,
            sync: Some(request_snapshot(sync, pubsub_instance, owner, False)),
          )
        False -> actor_state
      }
    }
    None, _, _
    | _, None, _
    | _, _, pubsub.System
    | _, _, pubsub.FromSocket(_, _)
    -> actor_state
  }
}

fn handle_snapshot(
  actor_state: ActorState,
  reply: SyncReply,
) -> actor.Next(ActorState, Message) {
  case actor_state.sync {
    None -> actor.continue(actor_state)
    Some(sync) ->
      case dict.get(sync.requests, reply.owner) {
        Ok(pending) if pending.request == reply.request ->
          merge_remote_sync(
            ActorState(
              ..actor_state,
              sync: Some(
                SyncState(
                  ..sync,
                  requests: dict.delete(sync.requests, reply.owner),
                ),
              ),
            ),
            reply.owner,
            pending.round,
            reply.state,
          )
        // Duplicates and replies to requests cancelled by membership loss.
        Ok(_) | Error(Nil) -> actor.continue(actor_state)
      }
  }
}

fn merge_remote_sync(
  actor_state: ActorState,
  owner: process.Pid,
  round: Int,
  remote_state: State,
) -> actor.Next(ActorState, Message) {
  // Crash boundary — see internal.rescue. Version skew or bugs can produce
  // malformed sync state; Erlang distribution peers are fully trusted (see
  // the production-hardening guide). Preserve the previous actor state unless
  // merge, on_diff, prune, and read-model publication all complete.
  let processed =
    internal.rescue(fn() {
      let sender = state.replica(remote_state)
      case accepts_snapshot(actor_state, sender, owner, round) {
        False -> {
          log.debug(
            internal.logger("beryl.presence"),
            "Ignored stale presence incarnation",
            [
              #("replica", sender),
            ],
          )
          Error(Nil)
        }
        True -> merged_snapshot(actor_state, sender, remote_state)
      }
    })
  case processed {
    Ok(Ok(#(next_state, sender))) ->
      actor.continue(watch_replica(next_state, sender, owner, round))
    Ok(Error(Nil)) -> actor.continue(actor_state)
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

fn accepts_snapshot(
  actor_state: ActorState,
  sender: String,
  owner: process.Pid,
  round: Int,
) -> Bool {
  let base = state.base_replica(sender)
  !state.same_base(sender, state.replica(actor_state.crdt))
  && case actor_state.sync {
    None -> False
    Some(sync) ->
      case dict.get(sync.owners, base) {
        Error(Nil) -> True
        Ok(current) ->
          { current.replica == sender && current.pid == owner }
          || round > current.confirmed_round
      }
  }
}

/// Merge an accepted snapshot after retiring the sender's predecessors.
///
/// Returns an error when the sender conflicts with this replica's identity.
/// Dropping the round keeps local state authoritative.
fn merged_snapshot(
  actor_state: ActorState,
  sender: String,
  remote_state: State,
) -> Result(#(ActorState, String), Nil) {
  // accepts_snapshot rejects local-base senders first. Match the dependency
  // error too, so this library remains total if either contract changes.
  use #(crdt, _diff) <- result.try(
    state.supersede(actor_state.crdt, sender)
    |> result.map_error(fn(error) {
      let state.CannotSupersedeLocalReplica(local_replica, remote_replica) =
        error
      internal.logger("beryl.presence")
      |> log.error("Refused to retire the local presence replica", [
        #("local_replica", local_replica),
        #("remote_replica", remote_replica),
      ])
    }),
  )
  case state.merge(crdt, owner_snapshot(remote_state)) {
    Ok(crdt) -> {
      let #(crdt, _diff) = state.replica_up(crdt, sender)
      Ok(#(commit_replication(actor_state, crdt), sender))
    }
    Error(state.SameReplica(replica)) -> {
      telemetry.emit(
        actor_state.config.telemetry,
        telemetry.PresenceSyncRejected,
      )
      internal.logger("beryl.presence")
      |> log.error("Dropped presence sync that claims this replica identity", [
        #("local_replica", state.replica(actor_state.crdt)),
        #("remote_replica", sender),
        #("conflicting_replica", replica),
      ])
      Error(Nil)
    }
  }
}

fn commit_replication(actor_state: ActorState, crdt: State) -> ActorState {
  let diff = visible_diff(actor_state.crdt, crdt)
  maybe_invoke_on_diff(actor_state.config, diff)
  publish_topics(actor_state.read_table, crdt, diff_topics(diff))
  ActorState(..actor_state, crdt: crdt)
}
