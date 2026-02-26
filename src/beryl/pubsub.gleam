//// PubSub - Distributed publish/subscribe using Erlang pg
////
//// Provides topic-based pub/sub messaging backed by Erlang's built-in `pg`
//// module. Subscribers are tracked by process group, so messages are delivered
//// to all nodes in the cluster automatically.
////
//// ## Quick Start
////
//// ```gleam
//// let assert Ok(ps) = pubsub.start(pubsub.default_config())
//// pubsub.subscribe(ps, "room:lobby")
//// pubsub.broadcast(ps, "room:lobby", "new_msg", json.string("hello"))
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/json
import gleam/list

/// A PubSub message delivered to subscribers
pub type Message {
  Message(topic: String, event: String, payload: json.Json, from: PubSubFrom)
}

/// Identifies the sender of a broadcast
pub type PubSubFrom {
  /// Broadcast originated from the system (no sender pid)
  System
  /// Broadcast originated from a specific process
  FromPid(Pid)
}

/// PubSub configuration
pub type PubSubConfig {
  PubSubConfig(
    /// The pg scope name (atom). Different scopes are isolated.
    scope: Dynamic,
  )
}

/// A running PubSub instance
pub type PubSub {
  PubSub(scope: Dynamic)
}

/// Errors when starting PubSub
pub type StartError {
  PgStartFailed
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
fn ffi_send_to_pid(pid: Pid, msg: Message) -> Nil

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> Dynamic

// ── Public API ──────────────────────────────────────────────────────────────

/// Create a default PubSub configuration with scope `beryl_pubsub`
pub fn default_config() -> PubSubConfig {
  PubSubConfig(scope: binary_to_atom("beryl_pubsub"))
}

/// Create a PubSub configuration with a custom scope name
pub fn config_with_scope(name: String) -> PubSubConfig {
  PubSubConfig(scope: binary_to_atom(name))
}

/// Start a PubSub instance
///
/// This starts a pg scope. If the scope is already started (e.g., by another
/// node or previous call), this is a no-op.
pub fn start(config: PubSubConfig) -> Result(PubSub, StartError) {
  let result = ffi_start_pg_scope(config.scope)
  // pg:start returns {ok, Pid} or {error, {already_started, Pid}}
  // Both are success cases for us
  case dynamic.classify(result) {
    "Tuple" -> Ok(PubSub(scope: config.scope))
    _ -> Ok(PubSub(scope: config.scope))
  }
}

/// Subscribe the current process to a topic
///
/// The calling process will receive `Message` values when broadcasts
/// are sent to this topic.
pub fn subscribe(ps: PubSub, topic: String) -> Nil {
  let pid = process.self()
  let _ = ffi_join_group(ps.scope, topic, pid)
  Nil
}

/// Unsubscribe the current process from a topic
pub fn unsubscribe(ps: PubSub, topic: String) -> Nil {
  let pid = process.self()
  let _ = ffi_leave_group(ps.scope, topic, pid)
  Nil
}

/// Broadcast a message to all subscribers of a topic (all nodes)
pub fn broadcast(
  ps: PubSub,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  let msg = Message(topic: topic, event: event, payload: payload, from: System)
  let members = ffi_get_members(ps.scope, topic)
  list.each(members, fn(pid) { ffi_send_to_pid(pid, msg) })
}

/// Broadcast a message to all subscribers except those from a specific pid
pub fn broadcast_from(
  ps: PubSub,
  from: Pid,
  topic: String,
  event: String,
  payload: json.Json,
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

/// Broadcast a message to local subscribers only (current node)
pub fn local_broadcast(
  ps: PubSub,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  let msg = Message(topic: topic, event: event, payload: payload, from: System)
  let members = ffi_get_local_members(ps.scope, topic)
  list.each(members, fn(pid) { ffi_send_to_pid(pid, msg) })
}

/// Get all subscribers for a topic (all nodes)
pub fn subscribers(ps: PubSub, topic: String) -> List(Pid) {
  ffi_get_members(ps.scope, topic)
}

/// Get the number of subscribers for a topic (all nodes)
pub fn subscriber_count(ps: PubSub, topic: String) -> Int {
  list.length(ffi_get_members(ps.scope, topic))
}
