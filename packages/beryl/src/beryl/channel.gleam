//// The channel composition surface: a channel is a topic pattern paired
//// with a typed `join` callback and callbacks over private state.
////
//// ## Shape
////
//// ```gleam
//// import beryl/channel
//// import gleam/json
////
//// pub type Note {
////   Announce(String)
//// }
////
//// pub fn room() -> channel.Handler {
////   channel.handler("room:*", fn(context) {
////     channel.notify(context.self, Announce("later, on this topic"))
////
////     channel.accept(0)
////     |> channel.on_message(fn(count, message) {
////         channel.next(count + 1, [
////           channel.broadcast(message.event, json.int(count + 1)),
////         ])
////       })
////     |> channel.on_info(fn(count, note) {
////         let Announce(text) = note
////         channel.next(count, [
////           channel.push("announce", json.string(text)),
////         ])
////       })
////     |> channel.on_terminate(fn(_count, _reason) {
////         [channel.broadcast("left", json.string(context.topic))]
////       })
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
//// [`handler`](#handler) seals both inside its registration closure, so the
//// resulting [`Handler`](#handler) is not generic and handlers with unrelated
//// `state` and `info` types compose in one list. No value is
//// ever erased to `Dynamic` and no unchecked coercion is involved:
//// typed `info` values travel inside a closure that only the join which
//// created it can open. The socket that owns the join opens it. If the join
//// has ended, the socket drops it unopened.
////
//// ## Ordering
////
//// Action lists are applied strictly from left to right, and they always
//// target the channel's own topic. They lower onto
//// beryl's core `Effect` values, which the runtime applies in list order.
//// Action order is therefore wire order. An asynchronous presence effect can
//// park this socket while other sockets continue. The remaining actions
//// resume only after that effect completes.
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

import beryl
import beryl/presence
import beryl/socket
import beryl/topic
import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/erlang/reference
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/set

// ---------------------------------------------------------------------------
// Supervised channel system
// ---------------------------------------------------------------------------

/// Why building a channel-system child specification failed.
///
/// The function validates handler patterns before the core configuration. It
/// checks each pattern's syntax in registration order. It then checks for
/// exact duplicates in the same order. Overlapping patterns are allowed when
/// they are not identical because routing uses the first match.
pub type ChildSpecError {
  /// A handler used an invalid topic pattern.
  InvalidPattern(pattern: String, reason: topic.TopicError)
  /// Two handlers registered the same pattern string.
  DuplicatePattern(pattern: String)
  /// The core `beryl.Config` failed eager validation.
  InvalidConfig(reason: beryl.ConfigError)
}

/// Build a channel system's supervision child specification for embedding
/// in an application's supervision tree.
///
/// Like `beryl.child_spec`, this function reports only errors that it can
/// detect before the tree starts. It validates the handler table first and
/// then validates `beryl.Config`. You can use the returned `beryl.Sockets`
/// after the owning tree starts.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(#(sockets, child_specification)) =
///   channel.child_spec(
///     beryl.config(wire.phoenix_codec()),
///     handlers: [room.channel()],
///   )
///
/// let assert Ok(_root) =
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(child_specification)
///   |> static_supervisor.start()
/// ```
pub fn child_spec(
  config: beryl.Config,
  handlers handlers: List(Handler),
) -> Result(
  #(beryl.Sockets, supervision.ChildSpecification(static_supervisor.Supervisor)),
  ChildSpecError,
) {
  use table <- result.try(compile(handlers))

  beryl.child_spec(config, init: initialise(table), update: update)
  |> result.map_error(InvalidConfig)
}

fn compile(
  handlers: List(Handler),
) -> Result(List(Registered), ChildSpecError) {
  let patterns = list.map(handlers, fn(handler) { handler.pattern })
  use _ <- result.try(list.try_each(patterns, validate_pattern))
  use _ <- result.try(check_duplicates(patterns, set.new()))
  Ok(table(handlers))
}

fn initialise(
  table: List(Registered),
) -> fn(socket.ConnectInfo(Envelope)) -> #(Router, List(socket.Effect)) {
  fn(info) { init(table, info) }
}

fn validate_pattern(pattern: String) -> Result(String, ChildSpecError) {
  topic.validate_pattern(pattern)
  |> result.map_error(fn(error) {
    InvalidPattern(pattern: pattern, reason: error)
  })
}

fn check_duplicates(
  patterns: List(String),
  seen: set.Set(String),
) -> Result(Nil, ChildSpecError) {
  case patterns {
    [] -> Ok(Nil)
    [pattern, ..rest] ->
      case set.contains(seen, pattern) {
        True -> Error(DuplicatePattern(pattern))
        False -> check_duplicates(rest, set.insert(seen, pattern))
      }
  }
}

// ---------------------------------------------------------------------------
// Server-side sends
// ---------------------------------------------------------------------------

/// A typed handle for sending server-side messages to one joined channel.
///
/// Get this handle from [`JoinContext`](#joincontext) in the `join` callback.
/// You can share it with any process. The channel's `on_info` callback
/// receives each message with its type intact.
///
/// A sender is scoped to the join that produced it. Sending is asynchronous
/// and never fails. It cannot report that the channel is gone. The delivery
/// point checks liveness. It drops the message after a normal close, such as
/// a client leave, a [`close`](#close) result, or a socket teardown. It also
/// drops the message after the same topic is joined again. A different join
/// never receives the message.
///
/// The one exception is a panic inside [`on_terminate`](#on_terminate).
/// Core's policy for a crash while closing a topic is to log it and keep
/// the model from before the close, so the channel system keeps that
/// instance: a sender created by it can still reach its `on_info` until
/// the topic is joined again or the socket ends. Nothing is handed to
/// another join in that window. It is the *same* instance, outliving its own
/// termination.
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
/// Each call enqueues one message. Each enqueued message produces one
/// `on_info` call. The runtime does not combine sends. It delivers them in
/// the order that the owning socket receives them.
///
/// This is a fire-and-forget send. It returns when the message is enqueued,
/// whether or not the channel is still joined. The runtime discards a message
/// for a channel that has ended. See [`Sender`](#sender) for delivery cost and
/// the one case in which an ended channel can still receive a message.
pub fn notify(sender: Sender(info), message: info) -> Nil {
  sender.send(message)
}

/// Information about one join attempt.
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
    /// The client-supplied event name.
    event: String,
    /// The raw client payload, to decode with `gleam/dynamic/decode`.
    payload: dynamic.Dynamic,
    /// Reply correlation handle, when the client requested a reply.
    reply: option.Option(socket.ReplyRef),
  )
}

// ---------------------------------------------------------------------------
// Action builders
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
/// The phase parameter prevents [`on_terminate`](#on_terminate) from returning
/// active-only operations. Put actions in a list in wire order.
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
/// produces no effect.
pub fn reply_ok(
  reply: option.Option(socket.ReplyRef),
  payload: json.Json,
) -> Action(Active) {
  ReplyOkAction(Active, reply, payload)
}

/// Reply with an error when a client message supplied a reply handle.
///
/// [`option.None`](https://hexdocs.pm/gleam_stdlib/gleam/option.html#Option)
/// produces no effect.
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
/// Build one with [`next`](#next) or [`close`](#close). Use [`stay`](#stay)
/// when the state does not change and there are no actions.
pub opaque type Next(state) {
  NextContinue(state: state, actions: List(Action(Active)))
  NextClose(actions: List(Action(Active)))
}

/// Stay joined with the given state, applying `actions` in order.
pub fn next(state: state, actions: List(Action(Active))) -> Next(state) {
  NextContinue(state: state, actions: actions)
}

/// Stay joined with the given state and no actions.
pub fn stay(state: state) -> Next(state) {
  NextContinue(state: state, actions: [])
}

/// Leave this channel after applying `actions` in order.
///
/// The socket stays connected. Its other channels do not change. This
/// channel's [`on_terminate`](#on_terminate) callback still runs.
pub fn close(actions: List(Action(Active))) -> Next(state) {
  NextClose(actions: actions)
}

// ---------------------------------------------------------------------------
// Joined channels
// ---------------------------------------------------------------------------

type Callbacks(state, info) {
  Callbacks(
    message: fn(state, Message) -> Next(state),
    info: fn(state, info) -> Next(state),
    terminate: fn(state, socket.StopReason) -> List(Action(Closing)),
  )
}

fn callbacks() -> Callbacks(state, info) {
  Callbacks(
    message: fn(state, _message) { stay(state) },
    info: fn(state, _message) { stay(state) },
    terminate: fn(_state, _reason) { no_closing_actions() },
  )
}

fn no_closing_actions() -> List(Action(Closing)) {
  let Closing = Closing
  []
}

/// A live channel instance with `state` sealed in callback closures.
type SealedChannel(info) {
  SealedChannel(
    on_message: fn(Message) -> Continuation(info),
    on_info: fn(info) -> Continuation(info),
    on_terminate: fn(socket.StopReason) -> List(Action(Closing)),
  )
}

type Continuation(info) {
  ContinueWith(next: SealedChannel(info), actions: List(Action(Active)))
  CloseWith(actions: List(Action(Active)))
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
  }
}

// ---------------------------------------------------------------------------
// Join results
// ---------------------------------------------------------------------------

/// A `join` callback's answer: join this channel, or refuse.
///
/// Start an accepted result with [`accept`](#accept), then pipe it through
/// the `on_*` functions for the inputs that the channel handles. Unhandled
/// inputs keep the channel joined and produce no actions. [`handler`](#handler)
/// seals the private `state` and `info` types.
pub opaque type JoinResult(state, info) {
  JoinAccepted(
    state: state,
    callbacks: Callbacks(state, info),
    reply: option.Option(json.Json),
    actions: List(Action(Active)),
  )
  JoinRejected(reason: json.Json)
}

/// Accept the join with an empty acknowledgment.
///
/// Pipe the result through `on_message`, `on_info`, and `on_terminate` to
/// register the callbacks that the channel needs.
pub fn accept(state: state) -> JoinResult(state, info) {
  JoinAccepted(
    state: state,
    callbacks: callbacks(),
    reply: option.None,
    actions: [],
  )
}

/// Handle client messages on this channel's topic.
pub fn on_message(
  result: JoinResult(state, info),
  handle: fn(state, Message) -> Next(state),
) -> JoinResult(state, info) {
  case result {
    JoinRejected(_) -> result
    JoinAccepted(callbacks: callbacks, ..) ->
      JoinAccepted(..result, callbacks: Callbacks(..callbacks, message: handle))
  }
}

/// Handle typed server-side messages sent through this channel's
/// [`Sender`](#sender).
pub fn on_info(
  result: JoinResult(state, info),
  handle: fn(state, info) -> Next(state),
) -> JoinResult(state, info) {
  case result {
    JoinRejected(_) -> result
    JoinAccepted(callbacks: callbacks, ..) ->
      JoinAccepted(..result, callbacks: Callbacks(..callbacks, info: handle))
  }
}

/// Run cleanup when the channel ends for any reason: client leave, a
/// [`close`](#close) result, a socket teardown, or a disconnect.
///
/// The runtime applies the returned closing-phase actions in the turn that
/// closes this topic, after it removes the channel instance. This phase
/// allows broadcasts, presence untracking, and presence broadcasts. It does
/// not allow pushes, replies, or presence tracking.
///
/// A panic here is not fatal. Core keeps the model from before the close.
/// This instance stays in the channel system's map, and its
/// [`Sender`](#sender) can reach it until the topic is rejoined or the socket
/// ends.
pub fn on_terminate(
  result: JoinResult(state, info),
  handle: fn(state, socket.StopReason) -> List(Action(Closing)),
) -> JoinResult(state, info) {
  case result {
    JoinRejected(_) -> result
    JoinAccepted(callbacks: callbacks, ..) ->
      JoinAccepted(
        ..result,
        callbacks: Callbacks(..callbacks, terminate: handle),
      )
  }
}

/// Add a payload to an accepted join's acknowledgment.
///
/// A rejected join remains rejected.
pub fn with_reply(
  result: JoinResult(state, info),
  reply: json.Json,
) -> JoinResult(state, info) {
  case result {
    JoinRejected(_) -> result
    JoinAccepted(state: state, callbacks: callbacks, actions: actions, ..) ->
      JoinAccepted(
        state: state,
        callbacks: callbacks,
        reply: option.Some(reply),
        actions: actions,
      )
  }
}

/// Add ordered actions to an accepted join.
///
/// The runtime emits the actions with the acknowledgment and applies them
/// after it. The socket is therefore already subscribed to the topic. A
/// [`push`](#push) cannot overtake its own join reply. If an action becomes an
/// asynchronous presence effect, the runtime may process other sockets
/// while this socket waits. A check followed by
/// [`presence_track`](#presence_track) is not an atomic cross-socket capacity
/// reservation.
///
/// Use this function instead of notifying the channel from `join`:
/// [`notify`](#notify) schedules a *later* input, while actions preserve
/// their declared position immediately after the join acknowledgment.
///
/// Existing actions stay before the actions added here. A refused join has no
/// topic, so this function returns [`reject`](#reject) results unchanged.
pub fn with_actions(
  result: JoinResult(state, info),
  actions: List(Action(Active)),
) -> JoinResult(state, info) {
  case result {
    JoinRejected(_) -> result
    JoinAccepted(
      state: state,
      callbacks: callbacks,
      reply: reply,
      actions: existing,
    ) ->
      JoinAccepted(
        state: state,
        callbacks: callbacks,
        reply: reply,
        actions: list.append(existing, actions),
      )
  }
}

/// Refuse the join, returning `reason` to the client.
pub fn reject(reason: json.Json) -> JoinResult(state, info) {
  JoinRejected(reason: reason)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// A registered channel: a topic pattern plus its sealed `join` callback.
///
/// `Handler` is not generic. The closure contains the channel's sealed `state`
/// and `info` types. A single `List(Handler)` can therefore hold channels
/// with unrelated types.
pub opaque type Handler {
  Handler(pattern: String, open: fn(RoutedJoinContext) -> JoinOutcome)
}

/// Register a channel for every topic matching `pattern`.
///
/// `pattern` uses beryl's topic pattern syntax (`"room:lobby"`,
/// `"room:*"`, `"document:*:ops"`, `"*"`) and is validated when the
/// handler table is used by `channel.child_spec`.
///
/// `join` receives one [`JoinContext`](#joincontext) containing connection
/// data, the concrete topic, wildcard captures, and the payload.
pub fn handler(
  pattern: String,
  join: fn(JoinContext(info)) -> JoinResult(state, info),
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
      JoinAccepted(state, callbacks, reply, actions) ->
        Accepted(
          reply: reply,
          actions: actions,
          channel: live(seal(state, callbacks), handoff, join_id),
        )
    }
  })
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

// ---------------------------------------------------------------------------
// Private socket router
// ---------------------------------------------------------------------------

/// The socket-level message type of a channel system.
///
/// It carries no channel state and no typed `info` value: a `Mail` is a
/// sealed thunk that only the join which created it can open, and the
/// topic/generation pair says which join that is.
type Envelope {
  ChannelMail(topic: String, generation: Int, mail: Mail)
}

/// A handler with its topic pattern parsed once, at table build time.
type Registered {
  Registered(pattern: topic.TopicPattern, handler: Handler)
}

/// One live channel instance and the generation it was opened at.
type Instance {
  Instance(generation: Int, channel: LiveChannel)
}

/// The per-socket model.
type Router {
  Router(
    handlers: List(Registered),
    socket_id: String,
    seed: socket.ConnectSeed,
    self: socket.Sender(Envelope),
    /// The last generation handed out; strictly increasing, never reused.
    generation: Int,
    /// The topics this socket currently has an accepted instance on.
    live: dict.Dict(String, Instance),
  )
}

/// Parse every handler's pattern once, preserving registration order —
/// routing takes the first match, so order is the routing rule.
fn table(handlers: List(Handler)) -> List(Registered) {
  list.map(handlers, fn(handler) {
    Registered(pattern: topic.parse_pattern(handler.pattern), handler: handler)
  })
}

/// The `init` half of the pair: a socket starts with no joined channels.
fn init(
  handlers: List(Registered),
  info: socket.ConnectInfo(Envelope),
) -> #(Router, List(socket.Effect)) {
  let router =
    Router(
      handlers: handlers,
      socket_id: info.socket_id,
      seed: info.seed,
      self: info.self,
      generation: 0,
      live: dict.new(),
    )
  #(router, [])
}

/// The `update` half of the pair.
fn update(
  router: Router,
  input: socket.Input(Envelope),
) -> socket.Next(Router) {
  case input {
    socket.Join(topic: name, payload: payload, ref: ref) ->
      join(router, name, payload, ref)

    socket.Message(topic: name, event: event, payload: payload, ref: ref) ->
      on_live(router, name, fn(instance) {
        instance.channel.on_message(Message(
          event: event,
          payload: payload,
          reply: ref,
        ))
      })

    socket.Binary(..) -> socket.Next(router, [])

    socket.Closed(topic: name, reason: reason) -> closed(router, name, reason)

    socket.Info(ChannelMail(topic: name, generation: generation, mail: mail)) ->
      deliver(router, name, generation, mail)
  }
}

// --- joining ---------------------------------------------------------------

/// First match wins. An unmatched topic is refused explicitly rather than
/// left unanswered, so the client always learns why.
fn join(
  router: Router,
  name: String,
  payload: dynamic.Dynamic,
  ref: socket.JoinRef,
) -> socket.Next(Router) {
  case select(router.handlers, name) {
    Error(Nil) ->
      socket.Next(router, [socket.RejectJoin(ref, unmatched_topic())])
    Ok(#(handler, params)) ->
      open_join(router, handler, name, params, payload, ref)
  }
}

fn select(
  handlers: List(Registered),
  name: String,
) -> Result(#(Handler, List(String)), Nil) {
  case handlers {
    [] -> Error(Nil)
    [registered, ..rest] ->
      case topic.matches(registered.pattern, name) {
        False -> select(rest, name)
        True -> {
          let params =
            topic.extract_wildcards(registered.pattern, name)
            |> result.unwrap([])
          Ok(#(registered.handler, params))
        }
      }
  }
}

fn unmatched_topic() -> json.Json {
  json.object([#("reason", json.string("unmatched topic"))])
}

/// Allocate this join's generation, bind the channel's sends to it, and
/// run the handler.
///
/// The generation is bound into `deliver` *before* `open` runs,
/// because a `join` callback may notify itself; its mail has to be
/// addressed to the join being opened. The counter advances even when the
/// handler rejects, so a rejected join's sender can never collide with a
/// later accepted one.
fn open_join(
  router: Router,
  handler: Handler,
  name: String,
  params: List(String),
  payload: dynamic.Dynamic,
  ref: socket.JoinRef,
) -> socket.Next(Router) {
  let generation = router.generation + 1
  let router = Router(..router, generation: generation)
  let context =
    RoutedJoinContext(
      socket_id: router.socket_id,
      seed: router.seed,
      topic: name,
      params: params,
      payload: payload,
      deliver: mailbox(router.self, name, generation),
    )

  case open(handler, context) {
    // Only accepted joins become instances; a rejection leaves the socket
    // with no channel on this topic.
    Rejected(reason) -> socket.Next(router, [socket.RejectJoin(ref, reason)])
    Accepted(reply: reply, actions: actions, channel: live) -> {
      let instance = Instance(generation: generation, channel: live)
      socket.Next(
        Router(..router, live: dict.insert(router.live, name, instance)),
        // The acknowledgment is ordered ahead of the join's own actions,
        // so a push can never precede its own join reply and the
        // subscription the accept creates is already in place when they
        // run. Same turn, so nothing can interleave between them.
        [socket.AcceptJoin(ref, reply), ..effects(name, actions)],
      )
    }
  }
}

/// Bind one join's sends to its topic and generation. Every `notify`
/// produces exactly one envelope; nothing is coalesced.
fn mailbox(
  self: socket.Sender(Envelope),
  name: String,
  generation: Int,
) -> fn(Mail) -> Nil {
  fn(mail) {
    socket.notify(
      self,
      ChannelMail(topic: name, generation: generation, mail: mail),
    )
  }
}

// --- routing to a live instance --------------------------------------------

/// Run `callback` against the live instance for `name`, if there is one.
///
/// Inputs for a topic this socket has no accepted instance on are ignored:
/// a rejected join starts nothing, and a closed channel is gone.
fn on_live(
  router: Router,
  name: String,
  callback: fn(Instance) -> Step,
) -> socket.Next(Router) {
  case dict.get(router.live, name) {
    Error(Nil) -> socket.Next(router, [])
    Ok(instance) -> advance(router, name, instance, callback(instance))
  }
}

/// Deliver one sealed server-side message.
///
/// The envelope is checked against the live instance **before** the mail
/// is handed over, so a stale envelope — one from a closed channel or a
/// superseded generation — is dropped with its thunk still sealed and its
/// payload reaches nothing.
fn deliver(
  router: Router,
  name: String,
  generation: Int,
  mail: Mail,
) -> socket.Next(Router) {
  case dict.get(router.live, name) {
    Error(Nil) -> socket.Next(router, [])
    Ok(instance) ->
      case instance.generation == generation {
        False -> socket.Next(router, [])
        True -> advance(router, name, instance, instance.channel.on_mail(mail))
      }
  }
}

/// Lower one callback result onto the core.
fn advance(
  router: Router,
  name: String,
  instance: Instance,
  step: Step,
) -> socket.Next(Router) {
  case step {
    // The next instance keeps this join's generation: it is the same join.
    StepContinue(next: next, actions: actions) -> {
      let live =
        dict.insert(router.live, name, Instance(..instance, channel: next))
      socket.Next(Router(..router, live: live), effects(name, actions))
    }

    // Apply actions first, then kick. The instance stays live until the
    // `Closed` the kick produces arrives, so termination runs there — on
    // the one path every ending channel takes.
    StepClose(actions: actions) ->
      socket.Next(
        router,
        list.append(effects(name, actions), [socket.KickTopic(name)]),
      )
  }
}

// --- termination -----------------------------------------------------------

/// A joined topic ended, for any reason.
///
/// The instance is removed *before* its termination callback runs, so the
/// callback can neither be re-entered for this instance nor observe it as
/// live, and `Closed` is the only place termination happens — exactly
/// once per accepted join.
///
/// Termination actions are lowered inside this same `Closed` turn. Core
/// has already dropped the subscription and purged the topic's
/// outstanding reply refs by then, so it drops pushes to the closing
/// topic (including presence snapshots pushed to this socket) and drops
/// replies outright, while broadcasts still take effect. Core's automatic
/// topic untrack runs immediately *after* this turn, so a
/// `presence_track` here is undone as soon as it is applied — see
/// `on_terminate`.
///
/// The removal only sticks if this turn returns. When `on_terminate`
/// panics, core logs the crash and keeps the model from before this turn,
/// which is the one that still holds this instance at this generation. It
/// is not reachable from core's side — the topic is closed, so no client
/// message or `Closed` can name it again — but `Info` is
/// socket-scoped rather than topic-scoped, so a `Sender` created by this
/// join still finds it in `live` and still delivers `on_info` to it. The
/// entry goes away when the topic is joined again (`open` overwrites it)
/// or when the socket ends. This layer cannot narrow that window: undoing
/// it is exactly the model update the panic discarded, and rescuing the
/// callback here would hide a crash core is responsible for reporting.
fn closed(
  router: Router,
  name: String,
  reason: socket.StopReason,
) -> socket.Next(Router) {
  case dict.get(router.live, name) {
    Error(Nil) -> socket.Next(router, [])
    Ok(instance) -> {
      let router = Router(..router, live: dict.delete(router.live, name))
      socket.Next(router, effects(name, instance.channel.on_terminate(reason)))
    }
  }
}
