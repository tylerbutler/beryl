//// Native PubSub operations
////
//// This internal module keeps raw Erlang `pg`, process-subject, and message
//// operations behind typed Gleam functions. `beryl/pubsub` owns the public
//// API and wire contract. `beryl/pubsub_membership` uses the fallible
//// operations during scope recovery.

import beryl/error
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}

/// An error returned by a protected Erlang `pg` operation.
pub type PgError =
  error.OperationFailure

/// Registry-owned, protected readiness storage. The table dies with its owner.
pub type Readiness

/// A nonblocking query could not read a reconciled membership generation.
pub type QueryError {
  RegistryUnavailable
  ScopeRecovering
  PgUnavailable(PgError)
}

/// Create readiness storage in the membership actor, initially recovering.
@external(erlang, "beryl_pubsub_ffi", "new_readiness")
pub fn new_readiness() -> Readiness

/// Publish a pg generation only after stable local membership reconciliation.
@external(erlang, "beryl_pubsub_ffi", "publish_readiness")
pub fn publish_readiness(readiness: Readiness, pg: Pid) -> Nil

/// Clear readiness while the membership actor reconciles or recovers.
@external(erlang, "beryl_pubsub_ffi", "clear_readiness")
pub fn clear_readiness(readiness: Readiness) -> Nil

/// Return all members of a topic across connected nodes.
@external(erlang, "beryl_pubsub_ffi", "query_members")
pub fn get_members(
  scope: atom.Atom,
  readiness: Readiness,
  registry: Pid,
  topic: String,
) -> Result(List(Pid), QueryError)

/// Return members of a topic on the local node.
@external(erlang, "beryl_pubsub_ffi", "query_local_members")
pub fn get_local_members(
  scope: atom.Atom,
  readiness: Readiness,
  registry: Pid,
  topic: String,
) -> Result(List(Pid), QueryError)

/// Return the process registered for a `pg` scope.
@external(erlang, "beryl_pubsub_ffi", "registered_scope")
pub fn registered_scope(scope: atom.Atom) -> Result(Pid, Nil)

/// Join a local owner to a topic without raising an Erlang exception.
@external(erlang, "beryl_pubsub_ffi", "try_pg_join")
pub fn try_join(
  scope: atom.Atom,
  topic: String,
  owner: Pid,
) -> Result(Nil, PgError)

/// Leave a local owner from a topic without raising an Erlang exception.
@external(erlang, "beryl_pubsub_ffi", "try_pg_leave")
pub fn try_leave(
  scope: atom.Atom,
  topic: String,
  owner: Pid,
) -> Result(Nil, PgError)

/// Return local topic members without raising an Erlang exception.
@external(erlang, "beryl_pubsub_ffi", "try_pg_local_members")
pub fn try_local_members(
  scope: atom.Atom,
  topic: String,
) -> Result(List(Pid), PgError)

/// Build a typed subject for a known process and message tag.
@external(erlang, "gleam@erlang@process", "unsafely_create_subject")
pub fn subject_for_pid(pid: Pid, tag: atom.Atom) -> Subject(message)

/// Check whether a PID belongs to the local BEAM node.
@external(erlang, "beryl_pubsub_ffi", "is_local_pid")
pub fn is_local_pid(pid: Pid) -> Bool

@external(erlang, "erlang", "send")
fn raw_send(pid: Pid, message: message) -> message

/// Send one raw scope-tagged PubSub message to a subscriber.
pub fn send(
  pid: Pid,
  scope: atom.Atom,
  topic: String,
  event: String,
  payload: payload,
  from: from,
) -> Nil {
  case raw_send(pid, #(scope, topic, event, payload, from)) {
    _ -> Nil
  }
}

/// Convert a scope-and-arity-matched PubSub tuple to its message representation.
/// Field types rely on the same-scope caller obligation; they are not decoded.
@external(erlang, "beryl_pubsub_ffi", "scoped_to_message")
pub fn coerce_scoped_message(value: Dynamic) -> message
