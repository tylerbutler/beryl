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
//// // Receiving: fold `pubsub.selecting` into an actor's own `Selector`.
//// // `RemoteBroadcast` here is the actor's own message constructor that
//// // wraps an incoming `pubsub.Message(payload)`.
//// let selector =
////   process.new_selector()
////   |> process.select(subject)
////   |> pubsub.selecting(RemoteBroadcast)
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
/// `Message` is sent **raw between nodes** via `pg`, so its runtime shape —
/// the record tag and its four fields, in this order — is a frozen wire
/// contract, not just a source-level API, for any given `payload` type: a
/// rolling cluster upgrade must never mis-parse a frame from an older node
/// running the same payload type. The same applies to `PubSubFrom`.
///
/// Because payloads travel as native terms rather than a self-describing
/// format like JSON, evolving the *shape* of your own `payload` type is also
/// a wire change — version it yourself (e.g. an explicit `v` field) if it
/// needs to change across a rolling upgrade. Never construct or match on this
/// type directly from a raw process message; use `selecting`, which is the
/// one place that knows how to recover it safely.
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

@external(erlang, "beryl_pubsub_ffi", "send_to_pid")
fn ffi_send_to_pid(pid: Pid, msg: Message(payload)) -> Nil

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> Dynamic

/// Recover a `Message(payload)` from the raw process message `selecting`
/// matched on. Safe only because `selecting` first confirmed the message is
/// tagged `message` with exactly 4 fields, matching the shape `broadcast*`
/// always constructs.
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_to_message(value: Dynamic) -> Message(payload)

/// The single, statically-known atom every `Message` is tagged with on the
/// wire. Shared by every PubSub instance regardless of scope or payload
/// type, so it never grows the atom table beyond this one entry.
fn message_tag() -> atom.Atom {
  atom.create("message")
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

/// Subscribe the current process to a topic
///
/// The calling process will receive `Message(payload)` values when
/// broadcasts are sent to this topic. Add `selecting` to a `Selector` to
/// receive them.
pub fn subscribe(ps: PubSub(payload), topic: String) -> Nil {
  let pid = process.self()
  let _join_result = ffi_join_group(ps.scope, topic, pid)
  Nil
}

/// Unsubscribe the current process from a topic
pub fn unsubscribe(ps: PubSub(payload), topic: String) -> Nil {
  let pid = process.self()
  let _leave_result = ffi_leave_group(ps.scope, topic, pid)
  Nil
}

/// Add PubSub message delivery to a `Selector`, alongside a process's own
/// subjects.
///
/// `pg` tracks bare `Pid`s, so PubSub messages arrive as a raw process
/// message rather than through a typed `Subject`. This function is the one
/// place that knows how to recover a `Message(payload)` from that raw shape,
/// so callers never need to build their own `select_record` matcher or reach
/// for an unsafe coercion themselves.
///
/// ```gleam
/// let selector =
///   process.new_selector()
///   |> process.select(subject)
///   |> pubsub.selecting(RemoteBroadcast)
/// ```
pub fn selecting(
  selector: Selector(message),
  transform: fn(Message(payload)) -> message,
) -> Selector(message) {
  process.select_record(selector, message_tag(), 4, fn(raw) {
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
  list.each(members, fn(pid) { ffi_send_to_pid(pid, msg) })
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
      False -> ffi_send_to_pid(pid, msg)
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
      False -> ffi_send_to_pid(pid, msg)
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
  list.each(members, fn(pid) { ffi_send_to_pid(pid, msg) })
}

/// Get all subscribers for a topic (all nodes)
pub fn subscribers(ps: PubSub(payload), topic: String) -> List(Pid) {
  ffi_get_members(ps.scope, topic)
}

/// Get the number of subscribers for a topic (all nodes)
pub fn subscriber_count(ps: PubSub(payload), topic: String) -> Int {
  list.length(ffi_get_members(ps.scope, topic))
}
