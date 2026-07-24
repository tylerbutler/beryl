//// Types for building app-side dispatch systems with `beryl.child_spec`.
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

import gleam/dynamic.{type Dynamic}
import gleam/erlang/reference.{type Reference}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

/// A reply correlation handle.
///
/// Carried by `Join` and (when the client requested a reply) `Message`
/// inputs. Pass it back in `AcceptJoin`/`RejectJoin`/`ReplyOk`/`ReplyError`
/// effects. Message refs may be stored in the model and answered from a later
/// `update` turn (for example, after an async lookup completes). Join refs are
/// valid only for their pending join and carry a unique runtime token, so a
/// delayed completion for an older same-topic join cannot answer a replacement
/// or retry.
pub opaque type Ref {
  Ref(
    kind: RefKind,
    topic: String,
    join_ref: Option(String),
    msg_ref: Option(String),
    join_token: Option(Reference),
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
  Ref(
    kind: JoinRef,
    topic: topic,
    join_ref: join_ref,
    msg_ref: msg_ref,
    join_token: Some(reference.new()),
  )
}

@internal
pub fn make_message_ref(
  topic topic: String,
  join_ref join_ref: Option(String),
  msg_ref msg_ref: Option(String),
) -> Ref {
  Ref(
    kind: MessageRef,
    topic: topic,
    join_ref: join_ref,
    msg_ref: msg_ref,
    join_token: None,
  )
}

@internal
pub fn ref_is_join(ref: Ref) -> Bool {
  ref.kind == JoinRef
}

@internal
pub fn refs_match(first: Ref, second: Ref) -> Bool {
  first == second
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
/// an `Info` event. This is an ordinary typed send — no erasure involved.
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
