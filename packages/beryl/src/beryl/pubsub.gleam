//// Distributed PubSub with Erlang `pg`
////
//// This module provides topic-based PubSub backed by Erlang's built-in `pg`
//// module. Subscribers are tracked by process group, so messages are
//// delivered to all connected nodes in the cluster.
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
//// ## Same-scope payload contract
////
//// Payload compatibility is a caller obligation, not a runtime check. Every
//// handle and subscriber for one scope, on every connected node, must use the
//// same payload type and compatible native term representation. Repeated
//// `start` calls for one scope do not create isolated instances. Different
//// topics in that scope do not provide type isolation either.
////
//// Give incompatible payload types distinct, fixed configuration scopes:
////
//// ```gleam
//// let assert Ok(numbers): Result(pubsub.PubSub(Int), _) =
////   pubsub.start(pubsub.config_with_scope("my_app_numbers"))
//// let assert Ok(text): Result(pubsub.PubSub(String), _) =
////   pubsub.start(pubsub.config_with_scope("my_app_text"))
//// ```
////
//// These names are a bounded set of deployment constants, not names derived
//// from requests or tenants. A type annotation on a handle does not register
//// or validate a schema. Violating this contract can deliver a value of the
//// wrong type or crash a subscriber. Only trusted BEAM peers may participate.
////
//// ## Scope recovery and delivery
////
//// Each node runs a shared beryl PubSub supervisor. Each scope has its own
//// supervisor, membership registry, and `pg` process. The service outlives
//// the process that calls `start`. A `pg` restart preserves the registry,
//// which restores the topics of live local subscriber owners. Existing
//// handles remain valid, and repeated joins still create one membership.
////
//// Broadcasts are best-effort. During recovery, broadcasts and subscriber
//// queries return `Error(ScopeRecovering)` until local replay restores the
//// memberships of live owners. Queries do not wait for the membership actor:
//// they read a readiness marker tied to its exact reconciled pg generation.
//// After local replay they may still see partial remote membership.
//// Broadcasts are not buffered
//// or replayed, and `Ok(Nil)` does not confirm delivery. Each node must
//// start its own scope; local recovery is not a cluster-wide readiness barrier.
////
//// Startup and membership operations return typed errors during
//// service failure or recovery. A failed or timed-out join or leave may have
//// recorded its intent; failure does not roll it back. Retrying is idempotent.
//// See `start` for startup conflicts and loss of the membership registry.
////
//// ## Quick start
////
//// ```gleam
//// let assert Ok(pubsub_handle) = pubsub.start(pubsub.default_config())
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

import beryl/error
import beryl/pubsub_membership
import beryl/pubsub_native
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Selector}
import gleam/list
import gleam/result

/// A PubSub operation could not complete.
///
/// Failed or timed-out mutations may already have recorded their intent.
/// Retrying join and leave is idempotent; errors do not roll intent back.
pub type PubSubError {
  StartupFailed(error.OperationFailure)
  MembershipCallFailed(error.CallError)
  ScopeRecovering
  PgUnavailable(error.OperationFailure)
  OwnerNotLocal
}

/// Describe an operation failure, preserving bounded underlying diagnostics.
pub fn describe_error(failure: PubSubError) -> String {
  case failure {
    StartupFailed(reason) ->
      "PubSub startup failed: " <> error.describe_operation_failure(reason)
    MembershipCallFailed(reason) ->
      "PubSub membership call failed: " <> error.describe_call_error(reason)
    ScopeRecovering -> "PubSub scope recovering"
    PgUnavailable(reason) ->
      "PubSub pg unavailable: " <> error.describe_operation_failure(reason)
    OwnerNotLocal -> "PubSub owner is not local"
  }
}

fn registry_error_to_pubsub_error(
  failure: pubsub_membership.RegistryError,
) -> PubSubError {
  case failure {
    pubsub_membership.CallFailed(reason) -> MembershipCallFailed(reason)
    pubsub_membership.ScopeRecovering -> ScopeRecovering
    pubsub_membership.PgUnavailable(reason) -> PgUnavailable(reason)
    pubsub_membership.OwnerNotLocal -> OwnerNotLocal
  }
}

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
/// `selecting`. It adds the subscriber's raw mailbox messages to a typed
/// `Selector` under the same-scope payload contract. It does not validate
/// field types or payloads. Do not match the raw process message yourself.
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
/// All handles for one scope, across all connected nodes, must use the same
/// payload type and compatible native term representation. This is a caller
/// obligation, not a runtime-enforced guarantee.
pub opaque type PubSub(payload) {
  PubSub(scope: atom.Atom, registry: pubsub_membership.Registry)
}

// ── FFI declarations ────────────────────────────────────────────────────────

@external(erlang, "beryl_pubsub_ffi", "start_pg_scope")
fn ffi_start_pg_scope(
  scope: atom.Atom,
) -> Result(pubsub_membership.Registry, error.OperationFailure)

fn members(
  instance: PubSub(payload),
  topic: String,
  local_only: Bool,
) -> Result(List(Pid), PubSubError) {
  pubsub_membership.members(
    instance.registry,
    instance.scope,
    topic,
    local_only,
  )
  |> result.map_error(registry_error_to_pubsub_error)
}

/// Recover a `Message(payload)` from the raw process message `selecting`
/// matched on. `selecting` checks only the scope tag and arity; field types
/// rely on trusted senders that obey the same-scope payload contract.
fn unsafe_coerce_to_message(value: Dynamic) -> Message(payload) {
  pubsub_native.coerce_scoped_message(value)
}

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
/// This starts or attaches to a node-owned supervised scope. Repeated calls
/// share its membership registry; the first caller does not own its lifetime.
/// The registry restores live local subscriptions after a `pg` process restart.
/// Each participating node must start the same scope.
///
/// Startup errors return `StartupFailed` with the native reason. A scope
/// already owned by an external `pg` process is a startup conflict; beryl does
/// not adopt or stop it. Startup waits for supervision and local membership
/// reconciliation, but can fail if the service is recovering.
///
/// Loss of the registry itself, including supervisor restart-intensity
/// exhaustion, invalidates existing handles. Their membership, broadcast, and
/// subscriber-query calls return `MembershipCallFailed` rather than silently
/// using an empty replacement.
/// Call `start` again, create new subscribers, and rejoin their topics.
/// This is not persistent storage across service or node failure.
///
/// `payload` is fixed by how the returned value is used or annotated at the
/// call site. For example, annotate the successful handle as
/// `PubSub(MySyncPayload)`.
/// Starting the same scope again returns another handle to the same runtime
/// instance, so every use of that scope must choose the same payload type.
/// These calls do not create isolated instances or check payload compatibility.
/// Use distinct, fixed scopes for incompatible types, as in the module example.
pub fn start(config: PubSubConfig) -> Result(PubSub(payload), PubSubError) {
  use registry <- result.try(
    ffi_start_pg_scope(config.scope) |> result.map_error(StartupFailed),
  )
  use _ <- result.try(
    pubsub_membership.ready(registry)
    |> result.map_error(registry_error_to_pubsub_error),
  )
  Ok(PubSub(scope: config.scope, registry: registry))
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
  Subscriber(scope: atom.Atom, registry: pubsub_membership.Registry, owner: Pid)
}

/// A router's coalesced membership state.
@internal
pub opaque type AsyncSubscriber(payload) {
  AsyncSubscriber(
    subscriber: Subscriber(payload),
    intent: pubsub_membership.Intent,
  )
}

/// Create a router-owned subscriber with coalesced membership publication.
@internal
pub fn async_subscriber(instance: PubSub(payload)) -> AsyncSubscriber(payload) {
  AsyncSubscriber(subscriber(instance), pubsub_membership.new_intent())
}

/// Select messages for a router's asynchronous subscriber.
@internal
pub fn selecting_async(
  selector: Selector(message),
  subscriber: AsyncSubscriber(payload),
  transform: fn(Message(payload)) -> message,
) -> Selector(message) {
  selecting(selector, subscriber.subscriber, transform)
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
pub fn subscriber(pubsub_instance: PubSub(payload)) -> Subscriber(payload) {
  Subscriber(
    scope: pubsub_instance.scope,
    registry: pubsub_instance.registry,
    owner: process.self(),
  )
}

/// Join a topic so this subscriber receives broadcasts sent to it.
///
/// A subscriber can join many topics. All topics deliver to its owner's
/// mailbox. Repeated or concurrent joins create one membership per owner
/// process, scope, and topic, including joins through different handles.
/// Each broadcast delivers once to that owner, and subscriber counts include
/// it once.
///
/// The registry retains the membership through `pg` restarts and removes it
/// when its owner exits. During recovery this call can return `ScopeRecovering`
/// or `PgUnavailable`. Actor-call failures return `MembershipCallFailed`.
/// The call uses a five-second registry timeout; an error or timeout does not
/// roll back intent already recorded by the registry. Retrying is idempotent.
pub fn join(
  subscriber: Subscriber(payload),
  topic: String,
) -> Result(Nil, PubSubError) {
  pubsub_membership.join(subscriber.registry, topic, subscriber.owner)
  |> result.map_error(registry_error_to_pubsub_error)
}

/// Leave a topic previously joined with `join`.
///
/// One call removes the owner's membership for this scope and topic, even
/// after repeated joins through different handles. Repeated leaves are
/// harmless. Other owners, scopes, and topics are unaffected.
///
/// A leave removes recovery intent as well as live membership. Like `join`,
/// it returns a typed error during recovery or after a five-second timeout.
/// A failed call may still take effect; retrying is idempotent.
pub fn leave(
  subscriber: Subscriber(payload),
  topic: String,
) -> Result(Nil, PubSubError) {
  pubsub_membership.leave(subscriber.registry, topic, subscriber.owner)
  |> result.map_error(registry_error_to_pubsub_error)
}

/// Queue a join for the runtime router. The registry retries reconciliation.
@internal
pub fn join_async(
  subscriber: AsyncSubscriber(payload),
  topic: String,
) -> Result(Nil, Nil) {
  pubsub_membership.set_membership(
    subscriber.subscriber.registry,
    subscriber.intent,
    topic,
    True,
  )
}

/// Queue a leave for the runtime router. The registry retries reconciliation.
@internal
pub fn leave_async(
  subscriber: AsyncSubscriber(payload),
  topic: String,
) -> Result(Nil, Nil) {
  pubsub_membership.set_membership(
    subscriber.subscriber.registry,
    subscriber.intent,
    topic,
    False,
  )
}

/// Add a subscriber's PubSub message delivery to a `Selector`, alongside a
/// process's own subjects.
///
/// `pg` tracks bare pids, so broadcasts arrive as raw process messages.
/// `selecting` validates the subscriber's scope tag and four-field arity
/// before it recovers the compile-time payload type. It does not validate
/// topic, event, sender, or payload field types. Add it once. Every joined
/// topic uses the same mailbox.
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
  subscriber: Subscriber(payload),
  transform: fn(Message(payload)) -> message,
) -> Selector(message) {
  process.select_record(selector, subscriber.scope, 4, fn(raw) {
    transform(unsafe_coerce_to_message(raw))
  })
}

/// Broadcast a message to all topic subscribers on all nodes.
///
/// Registry and scope failures are returned before sending. Success means
/// best-effort dispatch, not confirmed delivery.
/// This does not wait for the registry actor; local recovery returns
/// `ScopeRecovering` until memberships have been replayed.
pub fn broadcast(
  pubsub_instance: PubSub(payload),
  topic: String,
  event: String,
  payload: payload,
) -> Result(Nil, PubSubError) {
  let message =
    Message(topic: topic, event: event, payload: payload, from: System)
  use members <- result.try(members(pubsub_instance, topic, False))
  list.each(members, fn(pid) {
    send_to_pid(pid, pubsub_instance.scope, message)
  })
  Ok(Nil)
}

/// Broadcast a message to all subscribers except a specific PID.
pub fn broadcast_from(
  pubsub_instance: PubSub(payload),
  from: Pid,
  topic: String,
  event: String,
  payload: payload,
) -> Result(Nil, PubSubError) {
  let message =
    Message(topic: topic, event: event, payload: payload, from: FromPid(from))
  use members <- result.try(members(pubsub_instance, topic, False))
  members
  |> list.filter(fn(pid) { pid != from })
  |> list.each(send_to_pid(_, pubsub_instance.scope, message))
  Ok(Nil)
}

/// Send an internal message to one member obtained from `subscribers`.
///
/// Uses the same scoped wire tuple as broadcasts and records the calling PID.
@internal
pub fn send_to(
  pubsub_instance: PubSub(payload),
  member: Pid,
  topic: String,
  event: String,
  payload: payload,
) -> Nil {
  send_to_pid(
    member,
    pubsub_instance.scope,
    Message(topic:, event:, payload:, from: FromPid(process.self())),
  )
}

/// Broadcast a message to all subscribers except a process.
///
/// Preserve a socket ID that receiving runtimes must exclude locally.
pub fn broadcast_from_socket(
  pubsub_instance: PubSub(payload),
  from: Pid,
  except_socket_id: String,
  topic: String,
  event: String,
  payload: payload,
) -> Result(Nil, PubSubError) {
  let message =
    Message(
      topic: topic,
      event: event,
      payload: payload,
      from: FromSocket(from, except_socket_id),
    )
  use members <- result.try(members(pubsub_instance, topic, False))
  members
  |> list.filter(fn(pid) { pid != from })
  |> list.each(send_to_pid(_, pubsub_instance.scope, message))
  Ok(Nil)
}

/// Broadcast a message only to subscribers on the current node.
pub fn local_broadcast(
  pubsub_instance: PubSub(payload),
  topic: String,
  event: String,
  payload: payload,
) -> Result(Nil, PubSubError) {
  let message =
    Message(topic: topic, event: event, payload: payload, from: System)
  use members <- result.try(members(pubsub_instance, topic, True))
  list.each(members, fn(pid) {
    send_to_pid(pid, pubsub_instance.scope, message)
  })
  Ok(Nil)
}

/// Broadcast to other local subscribers using the unchanged scoped wire tuple.
@internal
pub fn local_broadcast_from(
  pubsub_instance: PubSub(payload),
  from: Pid,
  topic: String,
  event: String,
  payload: payload,
) -> Result(Nil, PubSubError) {
  let message =
    Message(topic: topic, event: event, payload: payload, from: FromPid(from))
  use members <- result.try(members(pubsub_instance, topic, True))
  members
  |> list.filter(fn(pid) { pid != from })
  |> list.each(send_to_pid(_, pubsub_instance.scope, message))
  Ok(Nil)
}

/// Return all topic subscribers on all nodes.
///
/// Recovery and registry failures are errors, not empty subscriber lists.
/// The query does not message or wait for the registry actor. Local recovery
/// returns `ScopeRecovering` until the original registry has reconciled the
/// current pg generation; remote membership may still be partial afterwards.
pub fn subscribers(
  pubsub_instance: PubSub(payload),
  topic: String,
) -> Result(List(Pid), PubSubError) {
  members(pubsub_instance, topic, False)
}

/// Return the number of topic subscribers on all nodes.
pub fn subscriber_count(
  pubsub_instance: PubSub(payload),
  topic: String,
) -> Result(Int, PubSubError) {
  subscribers(pubsub_instance, topic) |> result.map(list.length)
}

fn send_to_pid(pid: Pid, scope: atom.Atom, message: Message(payload)) -> Nil {
  pubsub_native.send(
    pid,
    scope,
    message.topic,
    message.event,
    message.payload,
    message.from,
  )
}
