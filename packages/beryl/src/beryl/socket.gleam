//// Types for building app-side dispatch systems with `beryl.start`.
////
//// With app-side dispatch the application owns routing: beryl delivers
//// every wire event for a socket to one `update` function, and the
//// function returns the next model plus a list of `Effect`s for beryl to
//// apply. There are no channel modules, no registry, and no type erasure —
//// each socket has a single `model` and a single `msg` type.
////
//// ## Effect ordering guarantee
////
//// Effects are applied strictly in list order, inside a single runtime
//// actor turn, and every frame for a socket is written by that single
//// actor — so list order is wire order. An `AcceptJoin` followed by a
//// `Push` in the same list is guaranteed to arrive as the join
//// acknowledgment first and the push second.

import beryl/presence.{type PresenceEntry}
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/option.{type Option}

/// A reply correlation handle.
///
/// Carried by `Join` and (when the client requested a reply) `Message`
/// inputs. Pass it back in `AcceptJoin`/`RejectJoin`/`ReplyOk`/`ReplyError`
/// effects. `Ref` is an ordinary value: it may be stored in the model and
/// used from a later `update` turn (for example, replying from an `Info`
/// input once an async lookup completes).
pub opaque type Ref {
  Ref(
    kind: RefKind,
    topic: String,
    join_ref: Option(String),
    msg_ref: Option(String),
  )
}

type RefKind {
  JoinRef
  MessageRef
}

// nolint: unused_exports -- package-internal constructors/accessors for the runtime; hidden from public docs with @internal
@internal
pub fn make_join_ref(
  topic topic: String,
  join_ref join_ref: Option(String),
  msg_ref msg_ref: Option(String),
) -> Ref {
  Ref(kind: JoinRef, topic: topic, join_ref: join_ref, msg_ref: msg_ref)
}

@internal
pub fn make_message_ref(
  topic topic: String,
  join_ref join_ref: Option(String),
  msg_ref msg_ref: Option(String),
) -> Ref {
  Ref(kind: MessageRef, topic: topic, join_ref: join_ref, msg_ref: msg_ref)
}

@internal
pub fn ref_is_join(ref: Ref) -> Bool {
  ref.kind == JoinRef
}

@internal
pub fn ref_topic(ref: Ref) -> String {
  ref.topic
}

@internal
pub fn ref_join_ref(ref: Ref) -> Option(String) {
  ref.join_ref
}

@internal
pub fn ref_msg_ref(ref: Ref) -> Option(String) {
  ref.msg_ref
}

/// Why a socket or topic is stopping.
///
/// Delivered in `Closed` inputs and accepted by `Stop`. Match with a
/// catch-all (`_`) arm: new stop reasons may be added in minor releases.
pub type StopReason {
  /// Normal shutdown (client left or disconnected cleanly).
  Normal
  /// Server-initiated shutdown (system stop, `KickTopic`).
  Shutdown
  /// The client failed to send a heartbeat within the configured timeout.
  HeartbeatTimeout
  /// Stopped because of an error (named `Errored` so importing it
  /// unqualified does not shadow the prelude's `Result` `Error`
  /// constructor).
  Errored(String)
}

/// Everything the runtime delivers to the app's `update` function.
pub type Input(msg) {
  /// A client asked to join a topic. Answer with `AcceptJoin` or
  /// `RejectJoin` in the returned effects; a `Join` left unanswered by the
  /// end of the update turn is rejected automatically (fail closed).
  Join(topic: String, payload: Dynamic, ref: Ref)
  /// A client message on a joined topic. `ref` is present for messages
  /// that expect a reply.
  Message(topic: String, event: String, payload: Dynamic, ref: Option(Ref))
  /// A binary frame on a joined topic (codecs without a binary decoder
  /// deliver the raw frame once per joined topic).
  Binary(topic: String, data: BitArray)
  /// A joined topic ended (client leave, kick, crash, or socket close).
  /// Delivered on every exit path — use it to prune per-topic state from
  /// the model. Frames pushed to the closing topic from this input are
  /// dropped; broadcasts still reach the topic's remaining subscribers.
  Closed(topic: String, reason: StopReason)
  /// A typed server-side message, sent via the socket's `Sender` (see
  /// `ConnectInfo.self` and `notify`).
  Info(msg)
}

/// The result of one `update` call: the next model plus effects to apply,
/// or an instruction to stop the whole socket.
pub type Next(model, msg) {
  /// Continue with the given model, applying the effects in order.
  Next(model: model, effects: List(Effect))
  /// Tear down the socket: every joined topic receives a `Closed` input,
  /// terminal frames are sent, and the transport connection is closed.
  Stop(reason: StopReason)
}

/// One update may return several effects, applied strictly in list order
/// (see the module docs for the ordering guarantee).
pub type Effect {
  /// Accept a pending join. Subscribes the socket to the topic and sends
  /// the join acknowledgment (with an optional reply payload). Only valid
  /// while the `Join` input's ref is pending.
  AcceptJoin(ref: Ref, reply: Option(Json))
  /// Reject a pending join with an error payload.
  RejectJoin(ref: Ref, reason: Json)
  /// Reply successfully to a client message ref.
  ReplyOk(ref: Ref, payload: Json)
  /// Reply with an error to a client message ref.
  ReplyError(ref: Ref, payload: Json)
  /// Push a server-initiated message to this socket on a joined topic.
  /// Pushes to topics this socket has not joined (yet) are dropped with a
  /// warning — order a `Push` after its topic's `AcceptJoin`.
  Push(topic: String, event: String, payload: Json)
  /// Broadcast to every subscriber of a topic (including this socket, when
  /// joined). Distributed via PubSub when configured.
  Broadcast(topic: String, event: String, payload: Json)
  /// Broadcast to every subscriber of a topic except this socket.
  BroadcastFrom(topic: String, event: String, payload: Json)
  /// Track this socket's presence under a key in a topic and broadcast the
  /// corresponding `presence_diff` join. Requires a presence handle on the
  /// config (`beryl.with_presence_handle`); dropped with a warning
  /// otherwise. Tracking an already-tracked key replaces the previous
  /// entry.
  PresenceTrack(topic: String, key: String, meta: Json)
  /// Untrack a presence previously tracked with `PresenceTrack` and
  /// broadcast the corresponding `presence_diff` leave. Remaining tracked
  /// keys are untracked automatically when their topic closes.
  PresenceUntrack(topic: String, key: String)
  /// Push a presence snapshot for a topic to this socket. Unlike a payload
  /// built inside `update` (which sees presence as it was *before* this
  /// effects list), `encode` runs when the effect is applied — after any
  /// earlier `PresenceTrack`/`PresenceUntrack` in the same list — so the
  /// entries already reflect them. Requires a presence handle
  /// (`beryl.with_presence_handle`); dropped with a warning otherwise.
  /// Like `Push`, dropped when the topic is not joined at that point.
  PushPresence(
    topic: String,
    event: String,
    encode: fn(List(PresenceEntry)) -> Json,
  )
  /// Broadcast a presence snapshot for a topic to all its subscribers,
  /// with the same apply-time `encode` semantics as `PushPresence`.
  /// Order it after the `PresenceTrack`/`PresenceUntrack` it should
  /// reflect.
  BroadcastPresence(
    topic: String,
    event: String,
    encode: fn(List(PresenceEntry)) -> Json,
  )
  /// Close this socket's subscription to a topic. The topic receives a
  /// `Closed(topic, Shutdown)` input and the client a terminal frame.
  KickTopic(topic: String)
}

/// Connection metadata assembled by the transport before the WebSocket
/// upgrade, delivered to the app's `init` via `ConnectInfo`.
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

/// An empty connect seed, for tests and transports with no request data.
pub fn empty_seed() -> ConnectSeed {
  ConnectSeed(path: "", query: [], headers: [], metadata: [])
}

/// A typed handle for sending server-side messages to one socket.
///
/// Obtained from `ConnectInfo.self` in `init`. Any process may call
/// `notify` with it; the message is delivered to the socket's `update` as
/// an `Info` input. This is an ordinary typed send — no erasure involved.
pub opaque type Sender(msg) {
  Sender(send: fn(msg) -> Nil)
}

// nolint: unused_exports -- package-internal constructor for the runtime; hidden from public docs with @internal
@internal
pub fn make_sender(send: fn(msg) -> Nil) -> Sender(msg) {
  Sender(send)
}

/// Send a typed server-side message to a socket. Delivered to the socket's
/// `update` function as `Info(message)`. Ignored if the socket has since
/// disconnected.
pub fn notify(sender: Sender(msg), message: msg) -> Nil {
  sender.send(message)
}

/// Everything the app's `init` receives when a socket connects.
pub type ConnectInfo(msg) {
  ConnectInfo(
    /// Unique id of the connecting socket.
    socket_id: String,
    /// Request data assembled by the transport.
    seed: ConnectSeed,
    /// Sender for delivering typed `Info` messages to this socket.
    self: Sender(msg),
  )
}
