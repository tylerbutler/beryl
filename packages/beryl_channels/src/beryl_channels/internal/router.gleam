//// The dispatch adapter: one handler table compiled into the
//// `init`/`update` pair `beryl.start` and `beryl.child_spec` expect.
////
//// This module is internal to `beryl_channels` (Gleam hides
//// `beryl_channels/internal/*` from other packages and from the generated
//// docs). Applications use `beryl_channels.start`/`child_spec`.
////
//// ## The model
////
//// Each socket gets exactly one [`Router`](#Router): the ordered handler
//// table, the core `socket.Sender(Envelope)` handed to `init`, a
//// dictionary of the topics this socket currently has a live channel on,
//// and a monotonically increasing generation counter.
////
//// A *generation* is allocated for every join attempt that reaches a
//// handler and is never reused, so an instance is identified by
//// `#(topic, generation)`. That pair is what makes a duplicate rejoin
//// safe: the old instance's senders are bound to a generation that is no
//// longer live, so their envelopes are dropped instead of being handed to
//// the new instance.
////
//// ## Process affinity (load-bearing)
////
//// `channel.open` and `LiveChannel.on_mail` **must run in the same
//// process**. `channel.handler` creates the join's typed hand-off subject
//// while running `open`, and only the process that created a subject may
//// receive from it; `on_mail` places the sealed value into that subject
//// and reads it back in the same turn.
////
//// This adapter satisfies that by construction: `open` runs from the
//// `Join` input and `on_mail` from the `Info` input, and beryl delivers
//// every input for a socket to `update` inside its own runtime actor
//// process. Nothing here may move either call onto another process — not
//// into a spawned task, not into a transport process.
//// `dispatch_test.join_and_info_run_in_the_same_runtime_process_test`
//// pins this.

import beryl/socket
import beryl/topic
import beryl_channels/channel
import gleam/dict
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option

/// The socket-level message type of a channel system.
///
/// It carries no channel state and no typed `info` value: a `Mail` is a
/// sealed thunk that only the join which created it can open, and the
/// topic/generation pair says which join that is.
pub type Envelope {
  ChannelMail(topic: String, generation: Int, mail: channel.Mail)
}

/// A handler with its topic pattern parsed once, at table build time.
pub type Registered {
  Registered(pattern: topic.TopicPattern, handler: channel.Handler)
}

/// One live channel instance and the generation it was opened at.
pub type Instance {
  Instance(generation: Int, channel: channel.LiveChannel)
}

/// The per-socket model.
pub type Router {
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
pub fn table(handlers: List(channel.Handler)) -> List(Registered) {
  list.map(handlers, fn(handler) {
    Registered(
      pattern: topic.parse_pattern(channel.pattern(handler)),
      handler: handler,
    )
  })
}

/// The `init` half of the pair: a socket starts with no joined channels.
pub fn init(
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
pub fn update(
  router: Router,
  input: socket.Input(Envelope),
) -> socket.Next(Router, Envelope) {
  case input {
    socket.Join(topic: name, payload: payload, ref: ref) ->
      join(router, name, payload, ref)

    socket.Message(topic: name, event: event, payload: payload, ref: ref) ->
      on_live(router, name, fn(instance) {
        instance.channel.on_message(channel.Message(
          topic: name,
          event: event,
          payload: payload,
          reply: ref,
        ))
      })

    socket.Binary(topic: name, data: data) ->
      on_live(router, name, fn(instance) { instance.channel.on_binary(data) })

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
  ref: socket.Ref,
) -> socket.Next(Router, Envelope) {
  case select(router.handlers, name) {
    option.None ->
      socket.Next(router, [socket.RejectJoin(ref, unmatched_topic())])
    option.Some(handler) -> open(router, handler, name, payload, ref)
  }
}

fn select(
  handlers: List(Registered),
  name: String,
) -> option.Option(channel.Handler) {
  case handlers {
    [] -> option.None
    [registered, ..rest] ->
      case topic.matches(registered.pattern, name) {
        True -> option.Some(registered.handler)
        False -> select(rest, name)
      }
  }
}

fn unmatched_topic() -> json.Json {
  json.object([#("reason", json.string("unmatched topic"))])
}

/// Allocate this join's generation, bind the channel's sends to it, and
/// run the handler.
///
/// The generation is bound into `deliver` *before* `channel.open` runs,
/// because a `join` callback may notify itself; its mail has to be
/// addressed to the join being opened. The counter advances even when the
/// handler rejects, so a rejected join's sender can never collide with a
/// later accepted one.
fn open(
  router: Router,
  handler: channel.Handler,
  name: String,
  payload: dynamic.Dynamic,
  ref: socket.Ref,
) -> socket.Next(Router, Envelope) {
  let generation = router.generation + 1
  let router = Router(..router, generation: generation)
  let context =
    channel.JoinContext(
      socket_id: router.socket_id,
      seed: router.seed,
      topic: name,
      payload: payload,
      deliver: mailbox(router.self, name, generation),
    )

  case channel.open(handler, context) {
    // Only accepted joins become instances; a rejection leaves the socket
    // with no channel on this topic.
    channel.Rejected(reason) ->
      socket.Next(router, [socket.RejectJoin(ref, reason)])
    channel.Accepted(reply: reply, actions: actions, channel: live) -> {
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
) -> fn(channel.Mail) -> Nil {
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
  callback: fn(Instance) -> channel.Step,
) -> socket.Next(Router, Envelope) {
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
  mail: channel.Mail,
) -> socket.Next(Router, Envelope) {
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
  step: channel.Step,
) -> socket.Next(Router, Envelope) {
  case step {
    // The next instance keeps this join's generation: it is the same join.
    channel.StepContinue(next: next, actions: actions) -> {
      let live =
        dict.insert(router.live, name, Instance(..instance, channel: next))
      socket.Next(Router(..router, live: live), effects(name, actions))
    }

    // Actions first, then the kick. The instance stays live until the
    // `Closed` the kick produces arrives, so termination runs there — on
    // the one path every ending channel takes.
    channel.StepClose(actions: actions) ->
      socket.Next(
        router,
        list.append(effects(name, actions), [socket.KickTopic(name)]),
      )

    // Stopping the socket carries no actions: every channel on it is
    // going away, and each still receives `Closed`.
    channel.StepStop(reason: reason) -> socket.Stop(reason)
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
/// has already dropped the subscription by then, so it drops pushes to
/// the closing topic (and the presence snapshots pushed to this socket)
/// while broadcasts and presence track/untrack still take effect — see
/// `channel.on_terminate`.
fn closed(
  router: Router,
  name: String,
  reason: socket.StopReason,
) -> socket.Next(Router, Envelope) {
  case dict.get(router.live, name) {
    Error(Nil) -> socket.Next(router, [])
    Ok(instance) -> {
      let router = Router(..router, live: dict.delete(router.live, name))
      socket.Next(router, effects(name, instance.channel.on_terminate(reason)))
    }
  }
}

// --- action lowering -------------------------------------------------------

/// Lower a channel's actions onto core effects, in order, all scoped to
/// the channel's own topic. Core applies effects in list order, so action
/// order is wire order.
fn effects(name: String, actions: List(channel.Action)) -> List(socket.Effect) {
  list.map(actions, fn(action) { effect(name, action) })
}

fn effect(name: String, action: channel.Action) -> socket.Effect {
  case action {
    channel.PushAction(event: event, payload: payload) ->
      socket.Push(topic: name, event: event, payload: payload)
    channel.BroadcastAction(event: event, payload: payload) ->
      socket.Broadcast(topic: name, event: event, payload: payload)
    channel.BroadcastFromAction(event: event, payload: payload) ->
      socket.BroadcastFrom(topic: name, event: event, payload: payload)
    channel.ReplyOkAction(reply: reply, payload: payload) ->
      socket.ReplyOk(ref: reply, payload: payload)
    channel.ReplyErrorAction(reply: reply, payload: payload) ->
      socket.ReplyError(ref: reply, payload: payload)
    channel.PresenceTrackAction(key: key, meta: meta) ->
      socket.PresenceTrack(topic: name, key: key, meta: meta)
    channel.PresenceUntrackAction(key: key) ->
      socket.PresenceUntrack(topic: name, key: key)
    channel.PushPresenceAction(event: event, encode: encode) ->
      socket.PushPresence(topic: name, event: event, encode: encode)
    channel.BroadcastPresenceAction(event: event, encode: encode) ->
      socket.BroadcastPresence(topic: name, event: event, encode: encode)
  }
}
