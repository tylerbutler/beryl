//// PubSub - Distributed publish/subscribe using Erlang pg
////
//// Provides topic-based pub/sub messaging backed by Erlang's built-in `pg`
//// module. Subscribers are tracked by process group, so messages are delivered
//// to all nodes in the cluster automatically.
////
//// The payload is generic: `PubSub(payload)` and `Message(payload)` carry
//// whatever Gleam type a given scope is started with. A broadcast sends that
//// value as a scope-tagged native BEAM term. There is no encoding step, even
//// across nodes, because Erlang's distribution protocol marshals arbitrary
//// terms. Use a `gleam/json` payload only when the data is also
//// destined for a JSON-speaking client (e.g. relayed on to a WebSocket
//// browser); payloads that never leave the cluster are cheaper and safer as
//// plain Gleam types.
////
//// ## Quick Start
////
//// ```gleam
//// let pubsub_handle = pubsub.start(pubsub.default_config())
////
//// // Sending: broadcast to all subscribers of a topic
//// pubsub.broadcast(pubsub_handle, "room:lobby", "new_msg", "hello")
////
//// // Receiving: create a `subscriber`, join topics, and fold its
//// // `selecting` into an actor's own `Selector`. `RemoteBroadcast` here is
//// // the actor's own message constructor that wraps a `pubsub.Message`.
//// let subscriber = pubsub.subscriber(pubsub_handle)
//// pubsub.join(subscriber, "room:lobby")
//// let selector =
////   process.new_selector()
////   |> process.select(subject)
////   |> pubsub.selecting(subscriber, RemoteBroadcast)
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Selector}
import gleam/list

/// A PubSub message delivered to subscribers.
///
/// This type is transparent. Subscribers can inspect the topic, event,
/// payload, and sender metadata in their process mailbox.
///
/// ## Frozen wire contract
///
/// beryl sends broadcasts **raw between nodes** through `pg` as a five-element
/// tuple. The PubSub scope atom comes first. The four message fields follow in
/// order. This scope-tagged runtime shape is the frozen wire contract for each
/// `payload` type. The contract also applies to `PubSubFrom`.
///
/// Payloads travel as native terms, not in a self-describing format such as
/// JSON. A change to the *shape* of your `payload` type is therefore a wire
/// change. Add your own version, for example an explicit `v` field, if the
/// shape must change during a rolling upgrade. Receive broadcasts with
/// `selecting`. It safely adds the subscriber's raw mailbox messages to a
/// typed `Selector`. Do not match the raw process message yourself.
pub type Message(payload) {
  Message(topic: String, event: String, payload: payload, from: PubSubFrom)
}

/// Identifies the sender of a broadcast.
///
/// Part of the frozen wire contract described on `Message`.
pub type PubSubFrom {
  /// The broadcast came from the system and has no sender PID.
  System
  /// The broadcast came from a specific process.
  FromPid(Pid)
  /// The broadcast came from a process and must exclude a socket ID.
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
/// This handle is opaque. Callers cannot forge pg scopes or depend on the
/// runtime representation. `payload` sets the Gleam type for every `Message`
/// sent through this instance. The scope identifies the runtime instance.
/// All handles for one scope must use the same payload type.
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

/// Create a default PubSub configuration with scope `beryl_pubsub`.
pub fn default_config() -> PubSubConfig {
  PubSubConfig(scope: atom.create("beryl_pubsub"))
}

/// Create a PubSub configuration with a custom scope name.
///
/// The scope name is converted to an Erlang atom via `binary_to_atom`.
/// Atoms are never garbage-collected, so the scope name must be a
/// **static, bounded deployment or configuration value**. Never use raw
/// user-derived, per-request, per-tenant, database-derived, or otherwise
/// unbounded high-cardinality runtime input. A deployment-controlled value
/// is acceptable only when validated or selected from a fixed bounded set.
/// A malicious or high-cardinality source can exhaust the BEAM atom table
/// and crash the VM.
///
/// ```gleam
/// // Correct: static deployment constant
/// pubsub.config_with_scope("my_app_pubsub")
///
/// // Correct: deployment-controlled and selected from a fixed bounded set
/// // pubsub.config_with_scope(config.pubsub_scope())
///
/// // WRONG: never do this
/// // pubsub.config_with_scope(user_request.tenant_id)
/// // pubsub.config_with_scope(database_row.name)
/// ```
pub fn config_with_scope(name: String) -> PubSubConfig {
  PubSubConfig(scope: atom.create(name))
}

/// Start a PubSub instance.
///
/// This starts a pg scope. If another node or an earlier call started the
/// scope, this function does nothing.
///
/// `payload` is fixed by how the returned value is used or annotated at the
/// call site. For example: `pubsub.start(config) : PubSub(MySyncPayload)`.
/// Starting the same scope again returns another handle to the same runtime
/// instance, so every use of that scope must choose the same payload type.
pub fn start(config: PubSubConfig) -> PubSub(payload) {
  // pg:start treats already-started as success; the FFI swallows both
  ffi_start_pg_scope(config.scope)
  PubSub(scope: config.scope)
}

/// A typed subscription handle owned by a single process.
///
/// A `Subscriber` contains the pg scope and owning process. It also carries
/// the payload type at compile time. Join it to any number of topics with
/// `join`. One `selecting` call receives their frozen raw `Message(payload)`
/// records as typed values.
///
/// Create it in the receiving process, such as an actor's initializer.
/// A `Subject` delivers messages only to its owner.
pub opaque type Subscriber(payload) {
  Subscriber(scope: atom.Atom, owner: Pid)
}

/// Create a subscription handle owned by the current process.
///
/// Call this function from the process that will receive broadcasts, such as
/// an actor initializer or test process. Then join topics and add `selecting`
/// to that process's `Selector`.
///
/// A process may create subscribers for multiple scopes and payload types.
/// `selecting` uses each subscriber's scope to keep their raw mailbox messages
/// separate.
pub fn subscriber(ps: PubSub(payload)) -> Subscriber(payload) {
  Subscriber(scope: ps.scope, owner: process.self())
}

/// Join a topic so this subscriber receives broadcasts sent to it.
///
/// A subscriber can join many topics. All topics deliver through its one
/// subject. Joining a topic is idempotent.
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
/// `selecting` validates the subscriber's scope tag and four-field arity
/// before it recovers the compile-time payload type. Add it once. Every
/// joined topic uses the same mailbox.
///
/// Subscribers for different scopes may safely use different payload types in
/// one process. All subscribers for the same scope must use the same payload
/// type.
///
/// ```gleam
/// let subscriber = pubsub.subscriber(pubsub_handle)
/// pubsub.join(subscriber, "room:lobby")
/// let selector =
///   process.new_selector()
///   |> process.select(subject)
///   |> pubsub.selecting(subscriber, RemoteBroadcast)
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

/// Broadcast a message to all topic subscribers on all nodes.
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

/// Broadcast a message to all subscribers except a specific PID.
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

/// Broadcast a message to all subscribers except a process.
///
/// Preserve a socket ID that receiving runtimes must exclude locally.
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
/// Broadcast a message only to subscribers on the current node.
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

/// Return all topic subscribers on all nodes.
pub fn subscribers(ps: PubSub(payload), topic: String) -> List(Pid) {
  ffi_get_members(ps.scope, topic)
}

/// Return the number of topic subscribers on all nodes.
pub fn subscriber_count(ps: PubSub(payload), topic: String) -> Int {
  list.length(ffi_get_members(ps.scope, topic))
}
