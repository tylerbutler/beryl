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
//// created it can open. The worker process that owns the join opens it. If
//// the join has ended, that process is gone and the value reaches nothing.
////
//// ## Processes and ordering
////
//// Each accepted topic runs in its own worker process under a supervisor
//// that its socket actor owns. The socket actor keeps the connection:
//// protocol state, refs, subscriptions, presence bookkeeping, and every
//// frame write. `join` runs while the worker starts, and the socket actor
//// waits for that one join (at most five seconds). `on_message` and
//// `on_info` run in the worker, which reports its actions back to the
//// socket actor.
////
//// Action lists are applied strictly from left to right, and they always
//// target the channel's own topic. They lower onto
//// beryl's core `Effect` values, which the runtime applies in list order.
//// Action order is therefore wire order for one topic. Between different
//// topics on one socket, no order is promised: their workers run
//// concurrently, as Phoenix channel processes do. An asynchronous presence
//// effect can park this socket while other sockets continue. The remaining
//// actions resume only after that effect completes.
////
//// A join's actions (see [`with_actions`](#with_actions)) are emitted with
//// the join acknowledgment, immediately after it: the socket is already
//// subscribed, so a push cannot precede its own join reply. This ordering
//// does not make an asynchronous presence mutation a cross-socket
//// reservation; use application-owned synchronous state for atomic
//// capacity checks.
////
//// A close reaches the worker after the messages it already holds, so a
//// push or reply computed before a leave is still delivered. Then
//// [`on_terminate`](#on_terminate) actions are lowered in the turn that
//// closes the topic, after the channel instance is gone. Its closing-phase
//// action type permits only operations that remain meaningful then.

import beryl
import beryl/presence
import beryl/socket
import beryl/topic
import gleam/dynamic
import gleam/erlang/process
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

  beryl.worker_child_spec(config, open_topic(table))
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
/// and never fails. It cannot report that the channel is gone. The message
/// goes to the worker process of that join. After the join ends, for any
/// reason, that process is gone and the message is dropped. A later join of
/// the same topic has a different worker, so a different join never
/// receives the message.
///
/// ## Cost
///
/// Each message is carried to the worker as a sealed thunk, and unsealing
/// it does a selective receive on the worker's own mailbox in the same
/// turn. That mailbox holds only this topic's work, so the cost is small.
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
/// for a channel that has ended. See [`Sender`](#sender) for delivery cost.
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
/// A panic here is not fatal. The runtime logs it, the close completes
/// without this callback's actions, and the worker process stops. A
/// [`Sender`](#sender) of this join then reaches nothing.
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
  Handler(
    pattern: String,
    open: fn(socket.WorkerContext, List(String)) -> socket.WorkerOutcome,
  )
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
  Handler(pattern: pattern, open: fn(context: socket.WorkerContext, params) {
    // The typed hand-off point for this join. It lives only inside this
    // closure, where `info` is still in scope, which is what lets
    // server-side sends stay typed without erasure.
    //
    // A `Sender` does *not* write to it directly: it seals the typed value
    // into a thunk and hands that to the runtime, which carries it to the
    // worker process that owns this join — the process running this very
    // function. Only there is the thunk run, through `on_info`, which
    // reads the value back at its original type in the same turn. Nothing
    // typed is ever left sitting in a process mailbox between turns, and
    // mail for a join that has ended reaches a process that no longer
    // exists.
    let handoff = process.new_subject()
    let sender =
      Sender(send: fn(message) {
        context.deliver(fn() { process.send(handoff, message) })
      })
    let join_context =
      JoinContext(
        socket_id: context.socket_id,
        seed: context.seed,
        self: sender,
        topic: context.topic,
        params: params,
        payload: context.payload,
      )

    case join(join_context) {
      JoinRejected(reason) -> socket.WorkerRejected(reason: reason)
      JoinAccepted(state, callbacks, reply, actions) ->
        socket.WorkerAccepted(
          reply: reply,
          effects: effects(context.topic, actions),
          worker: live(seal(state, callbacks), handoff, context.topic),
        )
    }
  })
}

// ---------------------------------------------------------------------------
// Worker seam
//
// Everything below is the package-internal representation the runtime
// consumes: one non-generic `socket.Worker` per accepted join, produced by
// the sealing above and run in the process the runtime started for that
// join. It never carries a typed `info` value.
// ---------------------------------------------------------------------------

/// Seal an accepted channel into the runtime's worker contract.
///
/// `handoff` is owned by the worker process — a handler's `open` runs in
/// the worker's initialiser — so a `Mail` placed there is read back at its
/// original type by `on_info`, in the same turn, and is never visible to
/// another join.
fn live(
  channel: SealedChannel(info),
  handoff: process.Subject(info),
  topic: String,
) -> socket.Worker {
  socket.Worker(
    on_message: fn(event, payload, reply) {
      Message(event: event, payload: payload, reply: reply)
      |> channel.on_message
      |> step(handoff, topic)
    },
    on_info: fn(mail) {
      // Unsealing and consuming happen back to back, so the typed value
      // is never visible to anything else.
      mail()
      case process.receive(handoff, 0) {
        Ok(message) -> step(channel.on_info(message), handoff, topic)
        // Unreachable: `deliver` is bound to this worker's own subject and
        // a mail places exactly one message on `handoff`, which this
        // process owns. Continuing unchanged keeps the arm harmless.
        Error(Nil) ->
          socket.WorkerContinue(
            next: live(channel, handoff, topic),
            effects: [],
          )
      }
    },
    on_terminate: fn(reason) { effects(topic, channel.on_terminate(reason)) },
  )
}

fn step(
  continuation: Continuation(info),
  handoff: process.Subject(info),
  topic: String,
) -> socket.WorkerStep {
  case continuation {
    ContinueWith(next, actions) ->
      socket.WorkerContinue(
        next: live(next, handoff, topic),
        effects: effects(topic, actions),
      )
    CloseWith(actions) -> socket.WorkerClose(effects: effects(topic, actions))
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
// Handler table
// ---------------------------------------------------------------------------

/// A handler with its topic pattern parsed once, at table build time.
type Registered {
  Registered(pattern: topic.TopicPattern, handler: Handler)
}

/// Parse every handler's pattern once, preserving registration order —
/// routing takes the first match, so order is the routing rule.
fn table(handlers: List(Handler)) -> List(Registered) {
  list.map(handlers, fn(handler) {
    Registered(pattern: topic.parse_pattern(handler.pattern), handler: handler)
  })
}

/// The runtime's `open` for a handler table, run in each new topic
/// worker. First match wins. An unmatched topic is refused explicitly
/// rather than left unanswered, so the client always learns why.
fn open_topic(
  handlers: List(Registered),
) -> fn(socket.WorkerContext) -> socket.WorkerOutcome {
  fn(context: socket.WorkerContext) {
    case select(handlers, context.topic) {
      Error(Nil) -> socket.WorkerRejected(unmatched_topic())
      Ok(#(handler, params)) -> open(handler, context, params)
    }
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

/// Run a handler's sealed `join` for one join attempt, in the calling
/// process. The runtime does this from a topic worker's initialiser,
/// through `open_topic`; tests call it directly.
@internal
pub fn open(
  handler: Handler,
  context: socket.WorkerContext,
  params: List(String),
) -> socket.WorkerOutcome {
  handler.open(context, params)
}
