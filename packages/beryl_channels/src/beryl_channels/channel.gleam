//// The channel composition surface: a channel is a topic pattern paired
//// with a typed `join` callback and callbacks over private state.
////
//// ## Shape
////
//// ```gleam
//// import beryl_channels/channel
//// import gleam/json
////
//// pub type Note {
////   Announce(String)
//// }
////
//// pub fn room() -> channel.Handler {
////   channel.handler("room:*", fn(context) {
////     let callbacks =
////       channel.callbacks()
////       |> channel.on_message(fn(count, message) {
////         channel.next(count + 1, [
////           channel.broadcast(message.event, json.int(count + 1)),
////         ])
////       })
////       |> channel.on_info(fn(count, note) {
////         let Announce(text) = note
////         channel.next(count, [
////           channel.push("announce", json.string(text)),
////         ])
////       })
////       |> channel.on_terminate(fn(_count, _reason) {
////         [channel.broadcast("left", json.string(context.topic))]
////       })
////
////     channel.notify(context.self, Announce("later, on this topic"))
////     channel.accept(0, callbacks)
////     |> channel.with_actions([
////       channel.push("welcome", json.string(context.topic)),
////     ])
////   })
//// }
//// ```
////
//// ## Type safety
////
//// A channel picks two types of its own: `state`, its private model, and
//// `info`, the type of server-side messages it accepts. Neither escapes:
//// [`accept`](#accept) seals `state` inside the callback closures, and
//// [`handler`](#handler) seals `info` inside the registration closure, so
//// the resulting [`Handler`](#handler) is not generic and handlers with
//// unrelated `state` and `info` types compose in one list. No value is
//// ever erased to `Dynamic` and no unchecked coercion is involved:
//// typed `info` values travel inside a closure that only the join which
//// created it can open, and the socket that owns the join opens it — or
//// drops it unopened, if the join has since ended.
////
//// ## Ordering
////
//// Action lists are applied strictly from left to right, and they always
//// target the channel's own topic. They lower onto
//// beryl's core `Effect` values, which the runtime applies in list order —
//// so action order is wire order. An asynchronous presence effect can park
//// this socket while other sockets continue; the remaining actions resume
//// only after that effect completes.
////
//// A join's actions (see [`with_actions`](#with_actions)) are emitted with
//// the join acknowledgment, immediately after it: the socket is already
//// subscribed, so a push cannot precede its own join reply. This ordering
//// does not make an asynchronous presence mutation a cross-socket
//// reservation; use application-owned synchronous state for atomic
//// capacity checks.
////
//// [`on_terminate`](#on_terminate) actions are lowered in the turn that
//// closes the topic, after the channel instance is gone. Its closing-phase
//// action type permits only operations that remain meaningful then.

import beryl/presence
import beryl/socket
import gleam/dynamic
import gleam/erlang/process
import gleam/erlang/reference
import gleam/json
import gleam/list
import gleam/option

// ---------------------------------------------------------------------------
// Server-side sends
// ---------------------------------------------------------------------------

/// A typed handle for sending server-side messages to one joined channel.
///
/// Obtained from [`JoinContext`](#joincontext) in the `join` callback and safe to
/// share with any process. Messages sent through it are delivered to the
/// channel's `on_info` callback with their type intact.
///
/// A sender is scoped to the join that produced it. Sending is
/// asynchronous and never fails, so it cannot report that the channel is
/// gone: liveness is decided where the message is delivered. After a
/// normal close — a client leave, a [`close`](#close) result, a socket
/// teardown — or after the same topic has been joined again, the message
/// is dropped there and is never handed to a different join.
///
/// The one exception is a panic inside [`on_terminate`](#on_terminate).
/// Core's policy for a crash while closing a topic is to log it and keep
/// the model from before the close, so the channel system keeps that
/// instance: a sender created by it can still reach its `on_info` until
/// the topic is joined again or the socket ends. Nothing is handed to
/// another join in that window either — it is the *same* instance,
/// outliving its own termination.
///
/// ## Cost
///
/// Delivery is cast-free but not free. Each message is carried to the
/// socket's runtime actor as a sealed thunk, and unsealing it does a
/// selective receive on that actor's mailbox in the same turn. A
/// selective receive scans the mailbox, so under a deep backlog on a busy
/// socket the cost of one delivery is O(mailbox depth). It is a
/// non-issue at ordinary depths; it is worth knowing before using
/// `notify` as a high-rate data path.
pub opaque type Sender(info) {
  Sender(send: fn(info) -> Nil)
}

/// Send a typed server-side message to the channel that owns `sender`.
///
/// Each call enqueues exactly one message, and each enqueued message
/// produces exactly one `on_info` call — sends are never coalesced, and
/// they are delivered in the order the owning socket receives them.
///
/// This is a fire-and-forget send: it returns as soon as the message is
/// enqueued, whether or not the channel is still joined. A message
/// enqueued for a channel that has already ended is discarded on arrival
/// (see [`Sender`](#sender), which also covers the cost of a delivery and
/// the one case where an ended channel still receives one).
pub fn notify(sender: Sender(info), message: info) -> Nil {
  sender.send(message)
}

/// Everything a `join` callback learns about one join attempt.
///
/// `params` contains wildcard captures in pattern order and is empty for
/// exact patterns. `self` is this channel's generation-scoped
/// [`Sender`](#sender), for scheduling a later turn.
pub type JoinContext(info) {
  JoinContext(
    /// Unique id of the socket that is joining.
    socket_id: String,
    /// Request data assembled by the transport before the upgrade.
    seed: socket.ConnectSeed,
    /// Typed sender for this channel instance.
    self: Sender(info),
    /// The concrete topic being joined.
    topic: String,
    /// Wildcard captures from the matched handler pattern.
    params: List(String),
    /// The client's raw join payload.
    payload: dynamic.Dynamic,
  )
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// A client message delivered to a joined channel's `on_message` callback.
///
/// `reply` is present only when the client asked for a reply; pass it to
/// [`reply_ok`](#reply_ok) or [`reply_error`](#reply_error).
pub type Message {
  Message(
    /// The topic this channel is joined to.
    topic: String,
    /// The client-supplied event name.
    event: String,
    /// The raw client payload, to decode with `gleam/dynamic/decode`.
    payload: dynamic.Dynamic,
    /// Reply correlation handle, when the client requested a reply.
    reply: option.Option(socket.ReplyRef),
  )
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// Marker for actions valid while a channel is active.
pub opaque type Active {
  Active
}

/// Marker for actions valid while a channel is closing.
pub opaque type Closing {
  Closing
}

/// One operation on the channel's own topic.
///
/// The phase parameter prevents active-only operations from being returned
/// by [`on_terminate`](#on_terminate). Put actions in a list in wire order.
pub opaque type Action(phase) {
  PushAction(phase: phase, event: String, payload: json.Json)
  BroadcastAction(event: String, payload: json.Json)
  BroadcastFromAction(event: String, payload: json.Json)
  ReplyOkAction(
    phase: phase,
    reply: option.Option(socket.ReplyRef),
    payload: json.Json,
  )
  ReplyErrorAction(
    phase: phase,
    reply: option.Option(socket.ReplyRef),
    payload: json.Json,
  )
  PresenceTrackAction(phase: phase, key: String, meta: json.Json)
  PresenceUntrackAction(key: String)
  PushPresenceAction(
    phase: phase,
    event: String,
    encode: fn(List(presence.PresenceEntry)) -> json.Json,
  )
  BroadcastPresenceAction(
    event: String,
    encode: fn(List(presence.PresenceEntry)) -> json.Json,
  )
}

/// Push a server-initiated message to this socket on this channel's topic.
pub fn push(event: String, payload: json.Json) -> Action(Active) {
  PushAction(Active, event, payload)
}

/// Broadcast to every subscriber of this channel's topic, including this
/// socket.
pub fn broadcast(event: String, payload: json.Json) -> Action(phase) {
  BroadcastAction(event, payload)
}

/// Broadcast to every subscriber of this channel's topic except this
/// socket.
pub fn broadcast_from(event: String, payload: json.Json) -> Action(phase) {
  BroadcastFromAction(event, payload)
}

/// Reply successfully when a client message supplied a reply handle.
///
/// [`option.None`](https://hexdocs.pm/gleam_stdlib/gleam/option.html#Option)
/// lowers to no effect.
pub fn reply_ok(
  reply: option.Option(socket.ReplyRef),
  payload: json.Json,
) -> Action(Active) {
  ReplyOkAction(Active, reply, payload)
}

/// Reply with an error when a client message supplied a reply handle.
///
/// [`option.None`](https://hexdocs.pm/gleam_stdlib/gleam/option.html#Option)
/// lowers to no effect.
pub fn reply_error(
  reply: option.Option(socket.ReplyRef),
  payload: json.Json,
) -> Action(Active) {
  ReplyErrorAction(Active, reply, payload)
}

/// Track this socket's presence under `key` on this channel's topic and
/// broadcast the matching `presence_diff` join.
///
/// Requires a presence handle on the `Config` (`beryl.with_presence_handle`).
pub fn presence_track(key: String, meta: json.Json) -> Action(Active) {
  PresenceTrackAction(Active, key, meta)
}

/// Untrack a presence previously tracked with
/// [`presence_track`](#presence_track) and broadcast the matching
/// `presence_diff` leave.
pub fn presence_untrack(key: String) -> Action(phase) {
  PresenceUntrackAction(key)
}

/// Push a presence snapshot for this channel's topic to this socket.
///
/// `encode` runs when the action is applied, so it already sees any
/// earlier [`presence_track`](#presence_track) or
/// [`presence_untrack`](#presence_untrack) in the same list.
pub fn push_presence(
  event: String,
  encode: fn(List(presence.PresenceEntry)) -> json.Json,
) -> Action(Active) {
  PushPresenceAction(Active, event, encode)
}

/// Broadcast a presence snapshot for this channel's topic to every
/// subscriber, with the same apply-time `encode` semantics as
/// [`push_presence`](#push_presence).
pub fn broadcast_presence(
  event: String,
  encode: fn(List(presence.PresenceEntry)) -> json.Json,
) -> Action(phase) {
  BroadcastPresenceAction(event, encode)
}

// ---------------------------------------------------------------------------
// Callback results
// ---------------------------------------------------------------------------

/// What a channel callback decided to do next.
///
/// Build one with [`next`](#next), [`close`](#close), or
/// [`stop_socket`](#stop_socket).
pub opaque type Next(state) {
  NextContinue(state: state, actions: List(Action(Active)))
  NextClose(actions: List(Action(Active)))
  NextStop(reason: socket.StopReason)
}

/// Stay joined with the given state, applying `actions` in order.
pub fn next(state: state, actions: List(Action(Active))) -> Next(state) {
  NextContinue(state: state, actions: actions)
}

/// Leave this channel after applying `actions` in order.
///
/// The socket stays connected and its other channels are untouched; this
/// channel's [`on_terminate`](#on_terminate) callback still runs.
pub fn close(actions: List(Action(Active))) -> Next(state) {
  NextClose(actions: actions)
}

/// Tear down the whole socket, not just this channel.
///
/// This deliberately carries no actions: the socket and every channel on
/// it are going away, so there is nothing left to apply them to.
pub fn stop_socket(reason: socket.StopReason) -> Next(state) {
  NextStop(reason: reason)
}

// ---------------------------------------------------------------------------
// Callbacks and joined channels
// ---------------------------------------------------------------------------

/// The typed callbacks of one channel, over its private `state` and its
/// server-side message type `info`.
///
/// Start from [`callbacks`](#callbacks) — which ignores every input and
/// stays joined — and override only what the channel cares about. Pass the
/// result to [`accept`](#accept) with the initial state.
pub opaque type Callbacks(state, info) {
  Callbacks(
    message: fn(state, Message) -> Next(state),
    binary: fn(state, BitArray) -> Next(state),
    info: fn(state, info) -> Next(state),
    terminate: fn(state, socket.StopReason) -> List(Action(Closing)),
  )
}

/// Callbacks that ignore every input and keep the channel joined.
pub fn callbacks() -> Callbacks(state, info) {
  Callbacks(
    message: fn(state, _message) { next(state, []) },
    binary: fn(state, _data) { next(state, []) },
    info: fn(state, _message) { next(state, []) },
    terminate: fn(_state, _reason) { no_closing_actions() },
  )
}

fn no_closing_actions() -> List(Action(Closing)) {
  let Closing = Closing
  []
}

/// Handle client messages on this channel's topic.
pub fn on_message(
  callbacks: Callbacks(state, info),
  handle: fn(state, Message) -> Next(state),
) -> Callbacks(state, info) {
  Callbacks(..callbacks, message: handle)
}

/// Handle binary frames on this channel's topic.
pub fn on_binary(
  callbacks: Callbacks(state, info),
  handle: fn(state, BitArray) -> Next(state),
) -> Callbacks(state, info) {
  Callbacks(..callbacks, binary: handle)
}

/// Handle typed server-side messages sent through this channel's
/// [`Sender`](#sender).
pub fn on_info(
  callbacks: Callbacks(state, info),
  handle: fn(state, info) -> Next(state),
) -> Callbacks(state, info) {
  Callbacks(..callbacks, info: handle)
}

/// Run cleanup when the channel ends, for any reason: client leave, a
/// [`close`](#close) result, a socket teardown, or a disconnect.
///
/// The returned closing-phase actions are applied in the turn that closes
/// this topic, right after the channel instance is gone. The phase allows
/// broadcasts, presence untracking, and presence broadcasts, while making
/// pushes, replies, and presence tracking unavailable.
///
/// A panic here is not fatal, but it is not free either: core keeps the
/// model from before the close, so this instance stays in the channel
/// system's map and its own [`Sender`](#sender) can still reach it until
/// the topic is rejoined or the socket ends.
pub fn on_terminate(
  callbacks: Callbacks(state, info),
  handle: fn(state, socket.StopReason) -> List(Action(Closing)),
) -> Callbacks(state, info) {
  Callbacks(..callbacks, terminate: handle)
}

/// A live channel instance with `state` sealed in callback closures.
type SealedChannel(info) {
  SealedChannel(
    on_message: fn(Message) -> Continuation(info),
    on_binary: fn(BitArray) -> Continuation(info),
    on_info: fn(info) -> Continuation(info),
    on_terminate: fn(socket.StopReason) -> List(Action(Closing)),
  )
}

type Continuation(info) {
  ContinueWith(next: SealedChannel(info), actions: List(Action(Active)))
  CloseWith(actions: List(Action(Active)))
  StopSocketWith(reason: socket.StopReason)
}

/// Bind private state to callbacks without erasing or coercing it.
fn seal(
  state: state,
  callbacks: Callbacks(state, info),
) -> SealedChannel(info) {
  SealedChannel(
    on_message: fn(message) {
      continuation(callbacks, callbacks.message(state, message))
    },
    on_binary: fn(data) {
      continuation(callbacks, callbacks.binary(state, data))
    },
    on_info: fn(message) {
      continuation(callbacks, callbacks.info(state, message))
    },
    on_terminate: fn(reason) { callbacks.terminate(state, reason) },
  )
}

fn continuation(
  callbacks: Callbacks(state, info),
  next: Next(state),
) -> Continuation(info) {
  case next {
    NextContinue(state, actions) ->
      ContinueWith(next: seal(state, callbacks), actions: actions)
    NextClose(actions) -> CloseWith(actions: actions)
    NextStop(reason) -> StopSocketWith(reason: reason)
  }
}

// ---------------------------------------------------------------------------
// Join results
// ---------------------------------------------------------------------------

/// A `join` callback's answer: join this channel, or refuse.
pub opaque type JoinResult(info) {
  JoinAccepted(
    channel: SealedChannel(info),
    reply: option.Option(json.Json),
    actions: List(Action(Active)),
  )
  JoinRejected(reason: json.Json)
}

/// Accept the join with an empty acknowledgment.
///
/// This seals the channel's private state inside its callbacks.
pub fn accept(
  state: state,
  callbacks: Callbacks(state, info),
) -> JoinResult(info) {
  JoinAccepted(channel: seal(state, callbacks), reply: option.None, actions: [])
}

/// Add a payload to an accepted join's acknowledgment.
///
/// A rejected join remains rejected.
pub fn with_reply(
  result: JoinResult(info),
  reply: json.Json,
) -> JoinResult(info) {
  case result {
    JoinRejected(_) -> result
    JoinAccepted(channel: channel, actions: actions, ..) ->
      JoinAccepted(
        channel: channel,
        reply: option.Some(reply),
        actions: actions,
      )
  }
}

/// Add ordered actions to run as part of accepting this join.
///
/// They are emitted with the acknowledgment and applied strictly after it,
/// so the socket is already subscribed to the topic: a [`push`](#push)
/// here cannot overtake its own join reply. If an action lowers to an
/// asynchronous presence effect, the runtime may process other sockets
/// while this socket waits; a check followed by [`presence_track`](#presence_track)
/// is therefore not an atomic cross-socket capacity reservation.
///
/// This is what to reach for instead of notifying yourself from `join`:
/// [`notify`](#notify) schedules a *later* input, while actions preserve
/// their declared position immediately after the join acknowledgment.
///
/// Actions already attached stay ahead of the ones added here. A refused
/// join has no topic to act on, so this returns [`reject`](#reject)
/// results unchanged.
pub fn with_actions(
  result: JoinResult(info),
  actions: List(Action(Active)),
) -> JoinResult(info) {
  case result {
    JoinRejected(_) -> result
    JoinAccepted(channel: channel, reply: reply, actions: existing) ->
      JoinAccepted(
        channel: channel,
        reply: reply,
        actions: list.append(existing, actions),
      )
  }
}

/// Refuse the join, returning `reason` to the client.
pub fn reject(reason: json.Json) -> JoinResult(info) {
  JoinRejected(reason: reason)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// A registered channel: a topic pattern plus its sealed `join` callback.
///
/// `Handler` is deliberately not generic. A channel's `state` and `info`
/// types are sealed inside the closure captured here, so a single
/// `List(Handler)` can hold channels that agree on nothing.
pub opaque type Handler {
  Handler(pattern: String, open: fn(RoutedJoinContext) -> JoinOutcome)
}

/// Register a channel for every topic matching `pattern`.
///
/// `pattern` uses beryl's topic pattern syntax (`"room:lobby"`,
/// `"room:*"`, `"document:*:ops"`, `"*"`) and is validated when the
/// handler table is used by `beryl_channels.child_spec`.
///
/// `join` receives one [`JoinContext`](#joincontext) containing connection
/// data, the concrete topic, wildcard captures, and the payload.
pub fn handler(
  pattern: String,
  join: fn(JoinContext(info)) -> JoinResult(info),
) -> Handler {
  Handler(pattern: pattern, open: fn(context: RoutedJoinContext) {
    // The typed hand-off point for this join. It lives only inside this
    // closure, where `info` is still in scope, which is what lets
    // server-side sends stay typed without erasure.
    //
    // A `Sender` does *not* write to it directly: it seals the typed value
    // into a `Mail` thunk and hands that to the router, which carries it
    // to the socket that owns this join. Only once the router has decided
    // the join is still live does it run the thunk — and it runs it
    // through `on_mail`, which reads the value back at its original type
    // in the same turn. Nothing typed is ever left sitting in a shared
    // process mailbox between turns.
    let handoff = process.new_subject()
    let join_id = reference.new()
    let sender =
      Sender(send: fn(message) {
        context.deliver(
          Mail(join: join_id, place: fn() { process.send(handoff, message) }),
        )
      })
    let join_context =
      JoinContext(
        socket_id: context.socket_id,
        seed: context.seed,
        self: sender,
        topic: context.topic,
        params: context.params,
        payload: context.payload,
      )

    case join(join_context) {
      JoinRejected(reason) -> Rejected(reason: reason)
      JoinAccepted(channel, reply, actions) ->
        Accepted(
          reply: reply,
          actions: actions,
          channel: live(channel, handoff, join_id),
        )
    }
  })
}

/// The topic pattern a handler was registered with.
pub fn pattern(handler: Handler) -> String {
  handler.pattern
}

// ---------------------------------------------------------------------------
// Router seam
//
// Everything below is the package-internal representation the router
// consumes. It is non-generic on purpose: it is what the sealing above
// produces, and it never carries a typed `info` value.
// ---------------------------------------------------------------------------

/// A joined channel with its `state` and `info` types fully sealed.
@internal
pub type LiveChannel {
  LiveChannel(
    on_message: fn(Message) -> Step,
    on_binary: fn(BitArray) -> Step,
    /// Deliver one enqueued server-side message to this channel's
    /// `on_info` callback.
    ///
    /// The router must call this **only after** it has confirmed that the
    /// `Mail` was addressed to this exact join — same topic, same
    /// generation — and must run each `Mail` at most once. `on_mail`
    /// unseals the typed value and runs the callback in a single turn, so
    /// no typed value is ever left behind for another turn, another
    /// generation, or the actor's catch-all selector to pick up. One
    /// `Mail` produces exactly one `on_info` call.
    ///
    /// A `Mail` belonging to a different join can never be delivered
    /// here: its value goes to the join that sealed it, so this returns
    /// an unchanged channel with no actions instead.
    on_mail: fn(Mail) -> Step,
    /// Run this channel's termination callback, returning the actions it
    /// asked for. The router runs them in the turn that closes the topic,
    /// after this instance has been removed.
    on_terminate: fn(socket.StopReason) -> List(Action(Closing)),
  )
}

/// One typed server-side message, sealed into a thunk.
///
/// Opaque and inert: it carries no payload the router can read, construct,
/// or redirect, and it has no effect at all until the join that sealed it
/// runs it through [`LiveChannel.on_mail`](#LiveChannel). Dropping a
/// `Mail` — which is what the router does for a stale topic or generation
/// — sends nothing anywhere, and handing one to the wrong join does
/// nothing either: it carries the identity of its own join.
@internal
pub opaque type Mail {
  Mail(join: reference.Reference, place: fn() -> Nil)
}

/// The non-generic form of a callback result.
@internal
pub type Step {
  StepContinue(next: LiveChannel, actions: List(Action(Active)))
  StepClose(actions: List(Action(Active)))
  StepStop(reason: socket.StopReason)
}

/// Everything the router supplies for one join attempt.
///
/// `deliver` is bound by the router to this topic and join generation. The
/// channel's `Sender` calls it with one sealed [`Mail`](#Mail) per
/// `notify`; the router is expected to carry that mail to the owning
/// socket as one envelope, check the envelope against the live join, and
/// then either run it through `on_mail` or drop it. Envelopes are never
/// coalesced: one send, one envelope, one `on_info`.
///
/// Bind `deliver` to the topic and generation this join is *about* to be
/// given, before calling [`open`](#open): a `join` callback may use its
/// own `Sender` to schedule a later turn, and the mail it enqueues has to
/// be addressed to the join being opened rather than to the previous one.
@internal
pub type RoutedJoinContext {
  RoutedJoinContext(
    socket_id: String,
    seed: socket.ConnectSeed,
    topic: String,
    params: List(String),
    payload: dynamic.Dynamic,
    deliver: fn(Mail) -> Nil,
  )
}

/// The non-generic form of a `JoinResult`.
///
/// `actions` are the join's accept-time actions, already in order. The
/// router must lower them **after** the accept effect and in the same
/// update turn.
@internal
pub type JoinOutcome {
  Accepted(
    reply: option.Option(json.Json),
    actions: List(Action(Active)),
    channel: LiveChannel,
  )
  Rejected(reason: json.Json)
}

/// Run a handler's sealed `join` callback for one join attempt.
@internal
pub fn open(handler: Handler, context: RoutedJoinContext) -> JoinOutcome {
  handler.open(context)
}

fn live(
  channel: SealedChannel(info),
  handoff: process.Subject(info),
  join_id: reference.Reference,
) -> LiveChannel {
  let unchanged = fn() {
    StepContinue(next: live(channel, handoff, join_id), actions: [])
  }
  LiveChannel(
    on_message: fn(message) {
      step(channel.on_message(message), handoff, join_id)
    },
    on_binary: fn(data) { step(channel.on_binary(data), handoff, join_id) },
    on_mail: fn(mail: Mail) {
      case mail.join == join_id {
        // Someone else's mail: leave it sealed, so its value stays where
        // its own join can still read it and reaches nothing here.
        False -> unchanged()
        True -> {
          // Unsealing and consuming happen back to back in this turn, so
          // the typed value is never visible to anything else.
          mail.place()
          case process.receive(handoff, 0) {
            Ok(message) -> step(channel.on_info(message), handoff, join_id)
            // Unreachable: this join sealed the mail and a mail places
            // exactly one message. Continuing unchanged keeps a router
            // mistake from taking the socket down with it.
            Error(Nil) -> unchanged()
          }
        }
      }
    },
    on_terminate: fn(reason) { channel.on_terminate(reason) },
  )
}

fn step(
  continuation: Continuation(info),
  handoff: process.Subject(info),
  join_id: reference.Reference,
) -> Step {
  case continuation {
    ContinueWith(next, actions) ->
      StepContinue(next: live(next, handoff, join_id), actions: actions)
    CloseWith(actions) -> StepClose(actions: actions)
    StopSocketWith(reason) -> StepStop(reason: reason)
  }
}

/// Lower actions to core effects, preserving strict left-to-right order.
///
/// Reply actions with no ref lower to zero effects.
@internal
pub fn effects(
  topic: String,
  actions: List(Action(phase)),
) -> List(socket.Effect) {
  list.flat_map(actions, fn(action) { effect(topic, action) })
}

fn effect(topic: String, action: Action(phase)) -> List(socket.Effect) {
  case action {
    PushAction(event: event, payload: payload, ..) -> [
      socket.Push(topic: topic, event: event, payload: payload),
    ]
    BroadcastAction(event: event, payload: payload) -> [
      socket.Broadcast(topic: topic, event: event, payload: payload),
    ]
    BroadcastFromAction(event: event, payload: payload) -> [
      socket.BroadcastFrom(topic: topic, event: event, payload: payload),
    ]
    ReplyOkAction(reply: option.None, ..)
    | ReplyErrorAction(reply: option.None, ..) -> []
    ReplyOkAction(reply: option.Some(reply), payload: payload, ..) -> [
      socket.ReplyOk(ref: reply, payload: payload),
    ]
    ReplyErrorAction(reply: option.Some(reply), payload: payload, ..) -> [
      socket.ReplyError(ref: reply, payload: payload),
    ]
    PresenceTrackAction(key: key, meta: meta, ..) -> [
      socket.PresenceTrack(topic: topic, key: key, meta: meta),
    ]
    PresenceUntrackAction(key: key) -> [
      socket.PresenceUntrack(topic: topic, key: key),
    ]
    PushPresenceAction(event: event, encode: encode, ..) -> [
      socket.PushPresence(topic: topic, event: event, encode: encode),
    ]
    BroadcastPresenceAction(event: event, encode: encode) -> [
      socket.BroadcastPresence(topic: topic, event: event, encode: encode),
    ]
  }
}
