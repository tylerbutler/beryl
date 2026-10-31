//// Types for building app-side dispatch systems with `beryl.child_spec`.
////
//// With app-side dispatch the application owns routing: beryl delivers
//// every wire event for a socket to one `update` function, and the
//// function returns the next model plus a list of `Effect`s for beryl to
//// apply. There are no channel modules, no registry, and no type erasure.
//// Each socket has a single `model` and a single `message` type.
////
//// ## Effect ordering guarantee
////
//// Effects are applied strictly in list order, and every frame for a
//// socket is written by that socket's own runtime actor — so list order
//// is wire order. An `AcceptJoin` followed by a `Push` in the same list
//// is guaranteed to arrive as the join acknowledgment first and the push
//// second.
////
//// Most effects are applied in one actor turn. `PresenceTrack` and
//// `PresenceUntrack` are the exception: they are applied by the presence
//// actor. beryl holds the rest of the list and every later input for that
//// socket until the mutation has been applied. It then continues exactly
//// where it left off. The visible order is unchanged (a
//// `PushPresence` after a `PresenceTrack` still sees the track), and the
//// socket's own inputs still arrive in the order the client sent them.
//// No other socket, broadcast, or heartbeat waits on that mutation. Those
//// continue, so a broadcast from elsewhere may arrive between two effects
//// from this socket.

import beryl/overload.{type AdmissionError}
import beryl/presence.{type PresenceEntry}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/reference.{type Reference}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

/// A pending join correlation handle.
///
/// Pass it back in `AcceptJoin` or `RejectJoin`. A join reference is valid only
/// for its pending join. It carries a unique runtime token. A delayed completion
/// for an older same-topic join cannot answer a replacement or retry.
///
/// The runtime links this handle to Phoenix's `join_ref` and message `ref`.
/// Return the exact handle from `Join`; do not reconstruct it from wire values.
pub opaque type JoinReference {
  JoinReference(
    topic: String,
    join_ref: Option(String),
    message_ref: Option(String),
    token: Reference,
  )
}

/// A client message reply correlation handle.
///
/// Pass it back in `ReplyOk`, `ReplyError`, or `DiscardReply`. You can store
/// reply references in the model and answer them in a later `update` turn, for
/// example after an asynchronous lookup. They do not expire. They are
/// single-use and remain valid only while the topic instance that received
/// the message stays open.
///
/// The runtime links this handle to Phoenix's per-message `ref` and channel
/// `join_ref`. The handle also carries a unique runtime token.
pub opaque type ReplyReference {
  ReplyReference(
    topic: String,
    join_ref: Option(String),
    message_ref: Option(String),
    token: Reference,
  )
}

@internal
pub fn make_join_reference(
  topic topic: String,
  join_ref join_ref: Option(String),
  message_ref message_ref: Option(String),
) -> JoinReference {
  JoinReference(
    topic: topic,
    join_ref: join_ref,
    message_ref: message_ref,
    token: reference.new(),
  )
}

@internal
pub fn make_reply_reference(
  topic topic: String,
  join_ref join_ref: Option(String),
  message_ref message_ref: Option(String),
) -> ReplyReference {
  ReplyReference(
    topic: topic,
    join_ref: join_ref,
    message_ref: message_ref,
    token: reference.new(),
  )
}

@internal
pub fn join_references_match(
  first: JoinReference,
  second: JoinReference,
) -> Bool {
  first == second
}

@internal
pub fn join_reference_topic(reference: JoinReference) -> String {
  reference.topic
}

@internal
pub fn reply_reference_topic(reference: ReplyReference) -> String {
  reference.topic
}

@internal
pub fn reply_reference_join_ref(reference: ReplyReference) -> Option(String) {
  reference.join_ref
}

@internal
pub fn reply_reference_message_ref(
  reference: ReplyReference,
) -> Option(String) {
  reference.message_ref
}

@internal
pub fn reply_reference_wire_key(
  reference: ReplyReference,
) -> #(String, Option(String), Option(String)) {
  #(reference.topic, reference.join_ref, reference.message_ref)
}

/// Why a socket or topic is stopping.
///
/// The runtime delivers this reason in `Closed` inputs, and `Stop` accepts it.
/// The variants are exhaustive; match each reason explicitly. Adding a
/// variant affects API compatibility and requires updating exhaustive matches.
pub type StopReason {
  /// Normal shutdown (client left or disconnected cleanly).
  Normal
  /// Server-initiated shutdown (system stop, `KickTopic`).
  Shutdown
  /// The client failed to send a heartbeat within the configured timeout.
  HeartbeatTimeout
  /// An error stopped the socket or topic. The name `Errored` prevents an
  /// unqualified import from shadowing the prelude's `Result` `Error`
  /// constructor.
  Errored(String)
  /// A local queue or callback result exceeded its admission budget.
  AdmissionRejected(AdmissionError)
}

/// Everything the runtime delivers to the app's `update` function.
pub type Input(message) {
  /// A client asked to join a topic. Return an `AcceptJoin` or `RejectJoin`
  /// effect. The runtime rejects a `Join` that is unanswered at the end of
  /// the update turn.
  Join(topic: String, payload: Dynamic, reference: JoinReference)
  /// A client message on a joined topic. `reference` is present for messages
  /// that expect a reply.
  Message(
    topic: String,
    event: String,
    payload: Dynamic,
    reference: Option(ReplyReference),
  )
  /// A binary frame on a joined topic (codecs without a binary decoder
  /// deliver the raw frame once per joined topic).
  Binary(topic: String, data: BitArray)
  /// A joined topic ended because of a client leave, kick, crash, or socket
  /// close. The runtime sends this input on every exit path. Use it to remove
  /// per-topic state from the model. Frames pushed to the closing topic are
  /// dropped; broadcasts still reach the topic's remaining subscribers.
  Closed(topic: String, reason: StopReason)
  /// A typed server-side message, sent via the socket's `Sender` (see
  /// `ConnectInfo.self` and `notify`).
  Info(message)
}

/// The result of one `update` call.
///
/// It contains the next model and effects, or an instruction to stop the
/// socket.
pub type Next(model) {
  /// Continue with the given model, applying the effects in order.
  Next(model: model, effects: List(Effect))
  /// Tear down the socket: every joined topic receives a `Closed` input,
  /// configured terminal frames are sent, and the transport connection is
  /// closed.
  Stop(reason: StopReason)
}

/// One update may return several effects, applied strictly in list order
/// (see the module docs for the ordering guarantee).
pub type Effect {
  /// Accept a pending join. This subscribes the socket to the topic and sends
  /// the join acknowledgment with an optional reply payload. The effect is
  /// valid only while the `Join` input's reference is pending.
  AcceptJoin(reference: JoinReference, reply: Option(Json))
  /// Reject a pending join with an error payload.
  RejectJoin(reference: JoinReference, reason: Json)
  /// Reply successfully to a client message reference.
  ReplyOk(reference: ReplyReference, payload: Json)
  /// Reply with an error to a client message reference.
  ReplyError(reference: ReplyReference, payload: Json)
  /// Discard a client message reference without sending a reply.
  ///
  /// Use this when the application intentionally will not answer a referenced
  /// message. It releases the retained socket capacity and permits later reuse
  /// of the same wire `ref`. A completed or stale reference has no effect.
  DiscardReply(reference: ReplyReference)
  /// Push a server-initiated message to this socket on a joined topic.
  /// The runtime drops pushes to topics that this socket has not joined and
  /// logs a warning. Put a `Push` after its topic's `AcceptJoin`.
  Push(topic: String, event: String, payload: Json)
  /// Broadcast to every subscriber of a topic (including this socket, when
  /// joined). Distributed via PubSub when configured.
  Broadcast(topic: String, event: String, payload: Json)
  /// Broadcast to every subscriber of a topic except this socket.
  BroadcastFrom(topic: String, event: String, payload: Json)
  /// Track this socket's presence under a key in a topic and broadcast the
  /// corresponding `presence_diff` join. This effect requires a presence
  /// handle on the config (`beryl.with_presence_handle`). Without a handle,
  /// the runtime drops the effect and logs a warning.
  ///
  /// Tracking an existing key replaces the previous entry atomically. The
  /// key is never absent during the replacement. One `presence_diff` contains
  /// both the leave and the join. Later effects wait for the mutation, as
  /// described in the module documentation. Other sockets do not wait.
  PresenceTrack(topic: String, key: String, meta: Json)
  /// Untrack a presence previously tracked with `PresenceTrack` and
  /// broadcast the corresponding `presence_diff` leave. When the topic
  /// closes, the runtime removes the remaining tracked keys in one batch and
  /// produces one aggregate leave diff. Later effects wait for the mutation,
  /// as described in the module documentation. Other sockets do not wait.
  /// This effect requires a presence handle (`beryl.with_presence_handle`).
  /// Without a handle, the runtime drops the effect and logs a warning.
  PresenceUntrack(topic: String, key: String)
  /// Push a presence snapshot for a topic to this socket. A payload built
  /// inside `update` sees presence from *before* this effects list. In
  /// contrast, `encode` runs when the effect is applied. It runs after earlier
  /// `PresenceTrack` and `PresenceUntrack` effects in the same list. The
  /// entries therefore include those changes.
  /// This effect requires a presence handle (`beryl.with_presence_handle`).
  /// Without a handle, the runtime drops the effect and logs a warning.
  /// Like `Push`, the runtime drops it if the topic is not joined.
  PushPresence(
    topic: String,
    event: String,
    encode: fn(List(PresenceEntry)) -> Json,
  )
  /// Broadcast a presence snapshot for a topic to all its subscribers,
  /// with the same apply-time `encode` semantics as `PushPresence`.
  /// Order it after the `PresenceTrack`/`PresenceUntrack` it should
  /// reflect. This effect requires a presence handle
  /// (`beryl.with_presence_handle`). Without a handle, the runtime drops the
  /// effect and logs a warning.
  BroadcastPresence(
    topic: String,
    event: String,
    encode: fn(List(PresenceEntry)) -> Json,
  )
  /// Close this socket's subscription to a topic. The topic receives
  /// `Closed(topic, Shutdown)`. If the codec has a close encoder, the client
  /// also receives its terminal frame.
  KickTopic(topic: String)
}

/// Return a `ReplyOk` effect when the client requested a reply.
///
/// `Message` inputs carry `Option(ReplyReference)`, while `ReplyOk` requires
/// a `ReplyReference`. This helper returns no effects for `None`.
pub fn reply_ok(
  reference: Option(ReplyReference),
  payload: Json,
) -> List(Effect) {
  case reference {
    Some(reply_reference) -> [ReplyOk(reply_reference, payload)]
    None -> []
  }
}

/// Connection metadata that the transport builds before the WebSocket
/// upgrade.
///
/// The app's `init` function receives it through `ConnectInfo`.
pub type ConnectSeed {
  ConnectSeed(
    /// Request path of the upgrade request (e.g. `"/socket"`).
    path: String,
    /// Query parameters of the upgrade request.
    query: List(#(String, String)),
    /// HTTP headers of the upgrade request.
    headers: List(#(String, String)),
    /// Transport- or app-provided extras (e.g. values produced by a
    /// transport `on_connect` hook).
    metadata: List(#(String, String)),
  )
}

/// Return an empty connect seed for tests and transports with no request data.
pub fn empty_seed() -> ConnectSeed {
  ConnectSeed(path: "", query: [], headers: [], metadata: [])
}

/// A typed handle for sending server-side messages to one socket.
///
/// Get this handle from `ConnectInfo.self` in `init`. Any process can call
/// `notify` with it. The socket's `update` function receives the message as
/// an `Info` event. This typed send does not erase the message type.
pub opaque type Sender(message) {
  Sender(
    send: fn(message) -> Result(Nil, AdmissionError),
    snapshot: fn() -> Result(overload.Occupancy, AdmissionError),
  )
}

@internal
pub fn make_sender(
  send: fn(message) -> Result(Nil, AdmissionError),
  snapshot: fn() -> Result(overload.Occupancy, AdmissionError),
) -> Sender(message) {
  Sender(send, snapshot)
}

/// Read socket queue accounting without waiting for its callback.
pub fn queue_snapshot(
  sender: Sender(message),
) -> Result(overload.Occupancy, AdmissionError) {
  sender.snapshot()
}

/// Send a typed server-side message to a socket.
///
/// The socket's `update` function receives `Info(message)`. The runtime
/// reports an admission error if the socket is closed or its queue is full.
/// `Ok` means admitted, not handled by the application's callback.
pub fn notify(
  sender: Sender(message),
  message: message,
) -> Result(Nil, AdmissionError) {
  sender.send(message)
}

/// Everything the app's `init` receives when a socket connects.
pub type ConnectInfo(message) {
  ConnectInfo(
    /// Unique id of the connecting socket.
    socket_id: String,
    /// Request data assembled by the transport.
    seed: ConnectSeed,
    /// Sender for delivering typed `Info` messages to this socket.
    self: Sender(message),
  )
}

// ---------------------------------------------------------------------------
// Topic worker seam
//
// These package-internal types connect the runtime to `beryl/channel`. The
// runtime starts one worker for each accepted join. The worker owns one topic
// and runs its callbacks. The socket actor applies the effects from the
// worker. Raw dispatch (`beryl.child_spec`) does not use these types because
// its model contains all topics for one socket.
// ---------------------------------------------------------------------------

/// One sealed server-side message for a topic worker.
///
/// Run it to put the typed value on a subject that the worker owns.
///
/// The worker's `on_info` reads the value at its original type in the same
/// turn. The runtime cannot read the value.
@internal
pub type Mail =
  fn() -> Nil

/// Everything the runtime supplies for one join attempt.
///
/// `deliver` sends one `Mail` to the new worker. The runtime binds `deliver`
/// before it runs `open`. Thus, a `join` callback that notifies itself sends
/// the message to the new join. The worker waits until the runtime indexes
/// the join before it handles the message.
@internal
pub type WorkerContext {
  WorkerContext(
    socket_id: String,
    seed: ConnectSeed,
    topic: String,
    payload: Dynamic,
    deliver: fn(Mail) -> Result(Nil, AdmissionError),
    queue_snapshot: fn() -> Result(overload.Occupancy, AdmissionError),
  )
}

/// A joined topic's callbacks with its `state` and `info` types sealed.
///
/// Each function runs in the worker process and returns core effects for the
/// worker's topic.
@internal
pub type Worker {
  Worker(
    on_message: fn(String, Dynamic, Option(ReplyReference)) -> WorkerStep,
    on_info: fn(Mail) -> WorkerStep,
    on_presence: Option(fn(presence.Event) -> WorkerStep),
    on_terminate: fn(StopReason) -> List(Effect),
  )
}

/// The result of one worker callback.
@internal
pub type WorkerStep {
  /// Apply `effects`, then keep serving with `next`.
  WorkerContinue(next: Worker, effects: List(Effect))
  /// Apply `effects`, then close the topic. `on_terminate` still runs.
  WorkerClose(effects: List(Effect))
}

/// The result of a worker's `join`.
///
/// `effects` contains the ordered accept-time effects. The runtime applies
/// them after the join acknowledgment in the same turn.
@internal
pub type WorkerOutcome {
  WorkerAccepted(reply: Option(Json), effects: List(Effect), worker: Worker)
  WorkerRejected(reason: Json)
}
