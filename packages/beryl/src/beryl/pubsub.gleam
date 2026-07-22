//// PubSub - Distributed publish/subscribe using Erlang pg
////
//// Provides topic-based pub/sub messaging backed by Erlang's built-in `pg`
//// module. Subscribers are tracked by process group, so messages are delivered
//// to all nodes in the cluster automatically.
////
//// The payload is generic: `PubSub(payload)` and `Message(payload)` carry
//// whatever Gleam type a given instance is started with. A broadcast sends
//// that value as a native BEAM term — there is no encoding step, even across
//// nodes, since Erlang's own distribution protocol marshals arbitrary terms
//// for you. Reach for a `gleam/json` payload only when the data is also
//// destined for a JSON-speaking client (e.g. relayed on to a WebSocket
//// browser); payloads that never leave the cluster are cheaper and safer as
//// plain Gleam types.
////
//// ## Quick Start
////
//// ```gleam
//// let ps = pubsub.start(pubsub.default_config())
//// pubsub.subscribe(ps, "room:lobby")
//// pubsub.broadcast(ps, "room:lobby", "new_msg", "hello")
////
//// // Receiving: create a `subscriber`, join topics, and fold its
//// // `selecting` into an actor's own `Selector`. `RemoteBroadcast` here is
//// // the actor's own message constructor that wraps a `pubsub.Message`.
//// let sub = pubsub.subscriber(ps)
//// pubsub.join(sub, "room:lobby")
//// let selector =
////   process.new_selector()
////   |> process.select(subject)
////   |> pubsub.selecting(sub, RemoteBroadcast)
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/list

/// A PubSub message delivered to subscribers.
///
/// This type is intentionally transparent so subscribers can inspect the topic,
/// event, payload, and sender metadata delivered to their process mailbox.
///
/// ## Frozen wire contract
///
/// A broadcast delivers this record to each subscriber via a typed
/// `Subject` whose tag is the statically-known atom shared by every PubSub
/// instance (see `subscriber`). The delivered term is therefore
/// `#(pubsub_tag, Message(...))` — the record tag and its four fields, in
/// this order, wrapped by that subject tag — and is a frozen wire contract,
/// not just a source-level API, for any given `payload` type: a rolling
/// cluster upgrade must never mis-parse a frame from an older node running
/// the same payload type. The same applies to `PubSubFrom`.
///
/// Because payloads travel as native terms rather than a self-describing
/// format like JSON, evolving the *shape* of your own `payload` type is also
/// a wire change — version it yourself (e.g. an explicit `v` field) if it
/// needs to change across a rolling upgrade. Receive broadcasts with
/// `selecting`, which folds a `subscriber`'s typed `Subject` into a
/// `Selector`; never match on the raw process message yourself.
pub type Message(payload) {
  Message(topic: String, event: String, payload: payload, from: PubSubFrom)
}

/// Identifies the sender of a broadcast.
///
/// Part of the frozen wire contract described on `Message`.
pub type PubSubFrom {
  /// Broadcast originated from the system (no sender pid)
  System
  /// Broadcast originated from a specific process
  FromPid(Pid)
  /// Broadcast originated from a process and should exclude a socket ID
  FromSocket(Pid, String)
}

/// PubSub configuration.
///
/// Build with `default_config` or `config_with_scope` so the underlying pg
/// scope representation can evolve without exposing record fields.
pub opaque type PubSubConfig {
  PubSubConfig(
    /// The pg scope name (atom). Different scopes are isolated.
    scope: Dynamic,
  )
}

/// A running PubSub instance.
///
/// This handle is intentionally opaque so callers cannot forge pg scopes or
/// depend on the runtime representation. `payload` fixes the Gleam type
/// every `Message` broadcast through this instance carries.
pub opaque type PubSub(payload) {
  PubSub(scope: Dynamic)
}

// ── FFI declarations ────────────────────────────────────────────────────────

@external(erlang, "beryl_pubsub_ffi", "start_pg_scope")
fn ffi_start_pg_scope(scope: Dynamic) -> Dynamic

@external(erlang, "beryl_pubsub_ffi", "join_group")
fn ffi_join_group(scope: Dynamic, group: String, pid: Pid) -> Dynamic

@external(erlang, "beryl_pubsub_ffi", "leave_group")
fn ffi_leave_group(scope: Dynamic, group: String, pid: Pid) -> Dynamic

@external(erlang, "beryl_pubsub_ffi", "get_members")
fn ffi_get_members(scope: Dynamic, group: String) -> List(Pid)

@external(erlang, "beryl_pubsub_ffi", "get_local_members")
fn ffi_get_local_members(scope: Dynamic, group: String) -> List(Pid)

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> Dynamic

/// The single, statically-known subject tag every PubSub broadcast is
/// delivered under. Shared by every PubSub instance regardless of scope or
/// payload type, so it never grows the atom table beyond this one entry, and
/// identical on every node so cross-node sends and receives agree.
fn pubsub_tag() -> Dynamic {
  binary_to_atom("beryl_pubsub_message")
}

/// Deliver a message to a subscriber pid through a typed `Subject`.
///
/// Reconstructs the receiver's subject from its pid and the shared
/// `pubsub_tag`, then sends with the ordinary typed `process.send`. This is
/// the send counterpart of `selecting`: both sides agree on the tag and the
/// `payload` type, so no value is ever coerced.
fn deliver(pid: Pid, msg: Message(payload)) -> Nil {
  process.send(process.unsafely_create_subject(pid, pubsub_tag()), msg)
}

// ── Public API ──────────────────────────────────────────────────────────────

/// Create a default PubSub configuration with scope `beryl_pubsub`
pub fn default_config() -> PubSubConfig {
  PubSubConfig(scope: binary_to_atom("beryl_pubsub"))
}

/// Create a PubSub configuration with a custom scope name
///
/// The scope name is converted to an Erlang atom via `binary_to_atom`.
/// Atoms are never garbage-collected, so the scope name must be a
/// **static, bounded deployment or configuration value** — never raw
/// user-derived, per-request, per-tenant, database-derived, or otherwise
/// unbounded high-cardinality runtime input. A deployment-controlled value
/// is acceptable only when validated or selected from a fixed bounded set.
/// A malicious or high-cardinality source can exhaust the BEAM atom table
/// and crash the VM.
///
/// ```gleam
/// // Correct — static deployment constant
/// pubsub.config_with_scope("my_app_pubsub")
///
/// // Correct — deployment-controlled, selected from a fixed bounded set
/// // pubsub.config_with_scope(config.pubsub_scope())
///
/// // WRONG — never do this
/// // pubsub.config_with_scope(user_request.tenant_id)
/// // pubsub.config_with_scope(database_row.name)
/// ```
pub fn config_with_scope(name: String) -> PubSubConfig {
  PubSubConfig(scope: binary_to_atom(name))
}

/// Start a PubSub instance
///
/// This starts a pg scope. If the scope is already started (e.g., by another
/// node or previous call), this is a no-op.
///
/// `payload` is fixed by how the returned value is used (or annotated) at the
/// call site — e.g. `pubsub.start(config) : PubSub(MySyncPayload)`.
pub fn start(config: PubSubConfig) -> PubSub(payload) {
  // pg:start returns {ok, Pid} or {error, {already_started, Pid}}
  // Both are success cases for us
  let _start_result = ffi_start_pg_scope(config.scope)
  PubSub(scope: config.scope)
}

/// A typed subscription handle owned by a single process.
///
/// A `Subscriber` bundles the pg scope with a typed `Subject(Message(payload))`
/// owned by the process that created it. Join it to any number of topics with
/// `join`; every topic delivers through the one subject, so a single
/// `selecting` fold receives them all. This is the typed replacement for
/// recovering a raw `Pid` mailbox message: broadcasts arrive as ordinary
/// typed sends, never as an unchecked coercion.
///
/// Create it in the process that will receive (e.g. an actor's initialiser),
/// since a `Subject` only delivers to its owner.
pub opaque type Subscriber(payload) {
  Subscriber(scope: Dynamic, subject: Subject(Message(payload)))
}

/// Create a subscription handle owned by the current process.
///
/// The returned `Subscriber` owns a typed subject keyed by the shared
/// `pubsub_tag`. Call it from the process that will receive broadcasts (its
/// own actor initialiser or test process), then `join` topics and fold
/// `selecting` into that process's `Selector`.
pub fn subscriber(ps: PubSub(payload)) -> Subscriber(payload) {
  Subscriber(
    scope: ps.scope,
    subject: process.unsafely_create_subject(process.self(), pubsub_tag()),
  )
}

/// Join a topic so this subscriber receives broadcasts sent to it.
///
/// A subscriber may join many topics; they all deliver through its one
/// subject. Joining is idempotent per topic.
pub fn join(sub: Subscriber(payload), topic: String) -> Nil {
  let assert Ok(pid) = process.subject_owner(sub.subject)
  let _join_result = ffi_join_group(sub.scope, topic, pid)
  Nil
}

/// Leave a topic previously joined with `join`.
pub fn leave(sub: Subscriber(payload), topic: String) -> Nil {
  let assert Ok(pid) = process.subject_owner(sub.subject)
  let _leave_result = ffi_leave_group(sub.scope, topic, pid)
  Nil
}

/// Add a subscriber's PubSub message delivery to a `Selector`, alongside a
/// process's own subjects.
///
/// Broadcasts arrive through the subscriber's typed `Subject`, so this is an
/// ordinary `select_map` — the `payload` type is checked by the compiler and
/// nothing is coerced. Fold it once; every joined topic is delivered through
/// the same subject.
///
/// ```gleam
/// let sub = pubsub.subscriber(ps)
/// pubsub.join(sub, "room:lobby")
/// let selector =
///   process.new_selector()
///   |> process.select(subject)
///   |> pubsub.selecting(sub, RemoteBroadcast)
/// ```
pub fn selecting(
  selector: Selector(message),
  sub: Subscriber(payload),
  transform: fn(Message(payload)) -> message,
) -> Selector(message) {
  process.select_map(selector, sub.subject, transform)
}

/// Broadcast a message to all subscribers of a topic (all nodes)
pub fn broadcast(
  ps: PubSub(payload),
  topic: String,
  event: String,
  payload: payload,
) -> Nil {
  let msg = Message(topic: topic, event: event, payload: payload, from: System)
  let members = ffi_get_members(ps.scope, topic)
  list.each(members, fn(pid) { deliver(pid, msg) })
}

/// Broadcast a message to all subscribers except those from a specific pid
pub fn broadcast_from(
  ps: PubSub(payload),
  from: Pid,
  topic: String,
  event: String,
  payload: payload,
) -> Nil {
  let msg =
    Message(topic: topic, event: event, payload: payload, from: FromPid(from))
  let members = ffi_get_members(ps.scope, topic)
  list.each(members, fn(pid) {
    case pid == from {
      True -> Nil
      False -> deliver(pid, msg)
    }
  })
}

/// Broadcast a message to all subscribers except a process, preserving a socket
/// ID that receiving channel coordinators should exclude locally.
pub fn broadcast_from_socket(
  ps: PubSub(payload),
  from: Pid,
  except_socket_id: String,
  topic: String,
  event: String,
  payload: payload,
) -> Nil {
  let msg =
    Message(
      topic: topic,
      event: event,
      payload: payload,
      from: FromSocket(from, except_socket_id),
    )
  let members = ffi_get_members(ps.scope, topic)
  list.each(members, fn(pid) {
    case pid == from {
      True -> Nil
      False -> deliver(pid, msg)
    }
  })
}

// nolint: unused_exports -- public PubSub API surface alongside broadcast/broadcast_from; intended for downstream consumers
/// Broadcast a message to local subscribers only (current node)
pub fn local_broadcast(
  ps: PubSub(payload),
  topic: String,
  event: String,
  payload: payload,
) -> Nil {
  let msg = Message(topic: topic, event: event, payload: payload, from: System)
  let members = ffi_get_local_members(ps.scope, topic)
  list.each(members, fn(pid) { deliver(pid, msg) })
}

/// Get all subscribers for a topic (all nodes)
pub fn subscribers(ps: PubSub(payload), topic: String) -> List(Pid) {
  ffi_get_members(ps.scope, topic)
}

/// Get the number of subscribers for a topic (all nodes)
pub fn subscriber_count(ps: PubSub(payload), topic: String) -> Int {
  list.length(ffi_get_members(ps.scope, topic))
}
