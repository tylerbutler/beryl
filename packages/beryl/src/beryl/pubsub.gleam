//// PubSub - Distributed publish/subscribe using Erlang pg
////
//// Provides topic-based pub/sub messaging backed by Erlang's built-in `pg`
//// module. Subscribers are tracked by process group, so messages are delivered
//// to all nodes in the cluster automatically.
////
//// The payload is generic: `PubSub(payload)` and `Message(payload)` carry
//// whatever Gleam type a given scope is started with. A broadcast sends that
//// value as a scope-tagged native BEAM term — there is no encoding step, even
//// across nodes, since Erlang's own distribution protocol marshals arbitrary
//// terms for you. Use a `gleam/json` payload only when the data is also
//// destined for a JSON-speaking client (e.g. relayed on to a WebSocket
//// browser); payloads that never leave the cluster are cheaper and safer as
//// plain Gleam types.
////
//// ## Quick Start
////
//// ```gleam
//// let ps = pubsub.start(pubsub.default_config())
////
//// // Sending: broadcast to all subscribers of a topic
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
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Selector}
import gleam/list

/// A PubSub message delivered to subscribers.
///
/// This type is intentionally transparent so subscribers can inspect the topic,
/// event, payload, and sender metadata delivered to their process mailbox.
///
/// ## Frozen wire contract
///
/// Beryl sends broadcasts **raw between nodes** via `pg` as a five-element tuple:
/// the PubSub scope atom followed by this message's four fields in order. That
/// scope-tagged runtime shape forms the frozen wire contract for each `payload`
/// type. The contract also applies to `PubSubFrom`.
///
/// Because payloads travel as native terms rather than a self-describing
/// format like JSON, evolving the *shape* of your own `payload` type is also
/// a wire change — version it yourself (e.g. an explicit `v` field) if it
/// needs to change across a rolling upgrade. Receive broadcasts with
/// `selecting`, which safely folds the subscriber's raw mailbox messages into
/// a typed `Selector`; never match on the raw process message yourself.
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
    /// The pg scope name. Different scopes are isolated and may use different
    /// payload types.
    scope: atom.Atom,
  )
}

/// A running PubSub instance.
///
/// This handle is intentionally opaque so callers cannot forge pg scopes or
/// depend on the runtime representation. `payload` fixes the Gleam type
/// every `Message` broadcast through this instance carries. The scope is the
/// runtime instance identity, so all handles using one scope must use the same
/// payload type.
pub opaque type PubSub(payload) {
  PubSub(scope: atom.Atom)
}

// ── FFI declarations ────────────────────────────────────────────────────────

@external(erlang, "beryl_pubsub_ffi", "start_pg_scope")
fn ffi_start_pg_scope(scope: atom.Atom) -> Nil

@external(erlang, "beryl_pubsub_ffi", "join_group")
fn ffi_join_group(scope: atom.Atom, group: String, pid: Pid) -> Nil

@external(erlang, "beryl_pubsub_ffi", "leave_group")
fn ffi_leave_group(scope: atom.Atom, group: String, pid: Pid) -> Nil

@external(erlang, "beryl_pubsub_ffi", "get_members")
fn ffi_get_members(scope: atom.Atom, group: String) -> List(Pid)

@external(erlang, "beryl_pubsub_ffi", "get_local_members")
fn ffi_get_local_members(scope: atom.Atom, group: String) -> List(Pid)

@external(erlang, "beryl_pubsub_ffi", "send_to_pid")
fn ffi_send_to_pid(pid: Pid, scope: atom.Atom, msg: Message(payload)) -> Nil

/// Recover a `Message(payload)` from the raw process message `selecting`
/// matched on. Safe only because `selecting` first confirms the message has the
/// subscriber's scope tag and exactly four fields, matching the frozen shape
/// all broadcast functions construct.
@external(erlang, "beryl_pubsub_ffi", "scoped_to_message")
fn unsafe_coerce_to_message(value: Dynamic) -> Message(payload)

// ── Public API ──────────────────────────────────────────────────────────────

/// Create a default PubSub configuration with scope `beryl_pubsub`
pub fn default_config() -> PubSubConfig {
  PubSubConfig(scope: atom.create("beryl_pubsub"))
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
  PubSubConfig(scope: atom.create(name))
}

/// Start a PubSub instance
///
/// This starts a pg scope. If the scope is already started (e.g., by another
/// node or previous call), this is a no-op.
///
/// `payload` is fixed by how the returned value is used (or annotated) at the
/// call site — e.g. `pubsub.start(config) : PubSub(MySyncPayload)`.
/// Starting the same scope again returns another handle to the same runtime
/// instance, so every use of that scope must choose the same payload type.
pub fn start(config: PubSubConfig) -> PubSub(payload) {
  // pg:start treats already-started as success; the FFI swallows both
  ffi_start_pg_scope(config.scope)
  PubSub(scope: config.scope)
}

/// A typed subscription handle owned by a single process.
///
/// A `Subscriber` bundles the pg scope and owning process while carrying the
/// payload type at compile time. Join it to any number of topics with `join`;
/// a single `selecting` fold receives their frozen raw `Message(payload)`
/// records as typed values.
///
/// Create it in the process that will receive (e.g. an actor's initialiser),
/// since a `Subject` only delivers to its owner.
pub opaque type Subscriber(payload) {
  Subscriber(scope: atom.Atom, owner: Pid)
}

/// Create a subscription handle owned by the current process.
///
/// Call it from the process that will receive broadcasts (its own actor
/// initialiser or test process), then `join` topics and fold `selecting` into
/// that process's `Selector`.
///
/// A process may create subscribers for multiple scopes and payload types.
/// `selecting` uses each subscriber's scope to keep their raw mailbox messages
/// separate.
pub fn subscriber(ps: PubSub(payload)) -> Subscriber(payload) {
  Subscriber(scope: ps.scope, owner: process.self())
}

/// Join a topic so this subscriber receives broadcasts sent to it.
///
/// A subscriber may join many topics; they all deliver through its one
/// subject. Joining is idempotent per topic.
pub fn join(sub: Subscriber(payload), topic: String) -> Nil {
  ffi_join_group(sub.scope, topic, sub.owner)
}

/// Leave a topic previously joined with `join`.
pub fn leave(sub: Subscriber(payload), topic: String) -> Nil {
  ffi_leave_group(sub.scope, topic, sub.owner)
}

/// Add a subscriber's PubSub message delivery to a `Selector`, alongside a
/// process's own subjects.
///
/// `pg` tracks bare pids, so broadcasts arrive as raw process messages.
/// `selecting` is the one place that validates the subscriber's scope tag and
/// four-field arity before recovering its compile-time payload type. Fold it
/// once; every joined topic is delivered through the same mailbox.
///
/// Subscribers for different scopes may safely use different payload types in
/// one process. All subscribers for the same scope must use the same payload
/// type.
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
  process.select_record(selector, sub.scope, 4, fn(raw) {
    transform(unsafe_coerce_to_message(raw))
  })
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
  list.each(members, fn(pid) { ffi_send_to_pid(pid, ps.scope, msg) })
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
  ffi_get_members(ps.scope, topic)
  |> list.filter(fn(pid) { pid != from })
  |> list.each(ffi_send_to_pid(_, ps.scope, msg))
}

/// Broadcast a message to all subscribers except a process, preserving a socket
/// ID that receiving runtimes should exclude locally.
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
  ffi_get_members(ps.scope, topic)
  |> list.filter(fn(pid) { pid != from })
  |> list.each(ffi_send_to_pid(_, ps.scope, msg))
}

// nolint: unused_exports -- public PubSub API intended for downstream consumers
/// Broadcast a message to local subscribers only (current node)
pub fn local_broadcast(
  ps: PubSub(payload),
  topic: String,
  event: String,
  payload: payload,
) -> Nil {
  let msg = Message(topic: topic, event: event, payload: payload, from: System)
  let members = ffi_get_local_members(ps.scope, topic)
  list.each(members, fn(pid) { ffi_send_to_pid(pid, ps.scope, msg) })
}

/// Get all subscribers for a topic (all nodes)
pub fn subscribers(ps: PubSub(payload), topic: String) -> List(Pid) {
  ffi_get_members(ps.scope, topic)
}

/// Get the number of subscribers for a topic (all nodes)
pub fn subscriber_count(ps: PubSub(payload), topic: String) -> Int {
  list.length(ffi_get_members(ps.scope, topic))
}
