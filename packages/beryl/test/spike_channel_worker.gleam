//// Prototype for [#337](https://github.com/tylerbutler/beryl/issues/337):
//// one temporary actor per accepted channel.
////
//// **This is a spike, not a second runtime.** It lives in `test/` because
//// it exists to be measured and argued about, not shipped. Nothing in
//// `src/` imports it.
////
//// ## What it reuses
////
//// Everything except the topology. Handlers, `join`, state sealing,
//// callbacks, actions, and action lowering are `beryl/channel`'s own —
//// `channel.open` produces the same non-generic `LiveChannel` the shipped
//// router holds, and `channel.effects` lowers the same actions. The only
//// difference is *which process* holds that `LiveChannel` and runs its
//// callbacks:
////
//// ```text
//// shipped:   runtime actor ── LiveChannel per topic (in its model)
//// spike:     runtime actor ── Worker(topic) ── LiveChannel
////                          └─ Worker(topic) ── LiveChannel
//// ```
////
//// So a benchmark against `channel.child_spec` compares topology alone.
////
//// ## Shape
////
//// - A `factory_supervisor` starts one `Temporary` worker per accepted
////   join. Temporary is the point: a worker whose join and authorization
////   state died must not be restarted behind the client's back.
//// - `join` runs **inside the worker's initialiser**, and the router waits
////   for it, because the core rejects a `Join` that is unanswered when the
////   update turn ends. There is no way to represent an asynchronous join
////   handshake against today's core.
//// - Everything after the join is asynchronous: the router casts work to
////   the worker, and the worker reports an action batch back through the
////   socket's own `Sender`, stamped with topic, generation, and sequence.
////   The router validates the stamp before applying anything.
//// - `on_terminate` is synchronous again, for the same reason `join` is:
////   its actions have to be lowered inside the `Closed` turn.
////
//// ## Known ceilings
////
//// `ponytail:` spike-scope cuts — no backpressure, no binary frames, no
//// pattern validation, workers not linked to their socket (nothing
//// per-socket exists to link them to), and a panicking `on_terminate`
//// stalling every socket for `terminate_timeout_ms` (see `finish`). Each
//// one's upgrade path, and what the prototype found, is in
//// `docs/spikes/0337-process-per-channel.md`.

import beryl
import beryl/channel
import beryl/socket
import beryl/topic
import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result

/// How long a `join` callback has to finish before the worker's start is
/// abandoned and the join rejected. The runtime actor is blocked for this
/// long in the worst case — a real design would want it much lower than
/// the supervisor's own call timeout, which is what actually bounds it.
const join_timeout_ms = 1000

/// How long the `Closed` turn waits for a worker's termination actions.
const terminate_timeout_ms = 1000

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

/// Work cast to one channel worker.
type Work {
  /// A client message for this channel's `on_message`.
  Deliver(message: channel.Message)
  /// One sealed server-side message for this channel's `on_info`.
  ///
  /// It arrives directly from the `Sender` that produced it, not by way of
  /// the router: the join that sealed the mail *is* this process, so
  /// process identity already carries the stamp the shipped router has to
  /// check by hand. Mail for an ended join reaches a dead pid and is
  /// dropped by the VM.
  DeliverMail(mail: channel.Mail)
  /// Run `on_terminate` and answer with its lowered actions, then stop.
  Finish(reply: process.Subject(List(socket.Effect)), reason: socket.StopReason)
  /// Stop without running any callback (a refused join has no channel).
  Halt
}

/// What the factory supervisor hands back to the router when a worker
/// starts.
type Report {
  /// The join was accepted. `effects` are its accept-time actions, already
  /// lowered and in order; the router must apply them after the accept.
  Opened(
    work: process.Subject(Work),
    reply: Option(json.Json),
    effects: List(socket.Effect),
  )
  /// The join was refused. The worker stops itself.
  Refused(reason: json.Json)
}

/// The factory supervisor's child argument: one join attempt.
type Spawn {
  Spawn(
    handler: channel.Handler,
    home: socket.Sender(Envelope),
    socket_id: String,
    seed: socket.ConnectSeed,
    topic: String,
    params: List(String),
    payload: dynamic.Dynamic,
    generation: Int,
  )
}

/// An accepted channel, owned by exactly one worker process.
type Channel {
  Channel(
    live: channel.LiveChannel,
    topic: String,
    generation: Int,
    /// Batches this worker has reported, monotonic from 1.
    sequence: Int,
    home: socket.Sender(Envelope),
  )
}

type State {
  Running(Channel)
  Refusing
}

/// Start one channel worker, running its `join` callback in the new
/// process.
///
/// A panic in `join` fails the start, which the router turns into a
/// rejection — the same observable outcome the shipped layer gets from
/// core's rescue boundary, by a different mechanism.
fn start_worker(spawn: Spawn) -> actor.StartResult(Report) {
  actor.new_with_initialiser(join_timeout_ms, fn(work) {
    let context =
      channel.RoutedJoinContext(
        socket_id: spawn.socket_id,
        seed: spawn.seed,
        topic: spawn.topic,
        params: spawn.params,
        payload: spawn.payload,
        deliver: fn(mail) { process.send(work, DeliverMail(mail)) },
      )

    case channel.open(spawn.handler, context) {
      channel.Rejected(reason) -> {
        process.send(work, Halt)
        Ok(actor.initialised(Refusing) |> actor.returning(Refused(reason)))
      }
      channel.Accepted(reply: reply, actions: actions, channel: live) ->
        Ok(
          actor.initialised(
            Running(Channel(
              live: live,
              topic: spawn.topic,
              generation: spawn.generation,
              sequence: 0,
              home: spawn.home,
            )),
          )
          |> actor.returning(Opened(
            work: work,
            reply: reply,
            effects: channel.effects(spawn.topic, actions),
          )),
        )
    }
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, work: Work) -> actor.Next(State, Work) {
  case state {
    Refusing -> actor.stop()
    Running(active) ->
      case work {
        Deliver(message: message) ->
          advance(active, active.live.on_message(message))
        DeliverMail(mail: mail) -> advance(active, active.live.on_mail(mail))
        Finish(reply: reply, reason: reason) -> {
          process.send(
            reply,
            channel.effects(active.topic, active.live.on_terminate(reason)),
          )
          actor.stop()
        }
        Halt -> actor.stop()
      }
  }
}

/// Report one callback result to the router and keep the next channel.
///
/// A worker never closes its own topic: `Closing` and `StopSocket` are
/// requests, and the worker stays alive until the router's `Closed` turn
/// asks it for its termination actions.
fn advance(current: Channel, step: channel.Step) -> actor.Next(State, Work) {
  let next = Channel(..current, sequence: current.sequence + 1)
  case step {
    channel.StepContinue(next: live, actions: actions) -> {
      report(next, Continue(channel.effects(next.topic, actions)))
      actor.continue(Running(Channel(..next, live: live)))
    }
    channel.StepClose(actions: actions) -> {
      report(next, Closing(channel.effects(next.topic, actions)))
      actor.continue(Running(next))
    }
    channel.StepStop(reason: reason) -> {
      report(next, StopSocket(reason))
      actor.continue(Running(next))
    }
  }
}

fn report(active: Channel, outcome: Outcome) -> Nil {
  socket.notify(
    active.home,
    Batch(
      topic: active.topic,
      generation: active.generation,
      sequence: active.sequence,
      outcome: outcome,
    ),
  )
}

/// Notify the socket when a worker exits, from a process that is allowed
/// to receive `DOWN`.
///
/// The router runs inside beryl's shared runtime actor and does not own
/// that actor's selector, so it cannot monitor anything itself. One
/// short-lived watcher per worker is the price of that, and it doubles the
/// per-channel process count — the first thing #334 would pay back.
fn watch(
  pid: process.Pid,
  home: socket.Sender(Envelope),
  name: String,
  generation: Int,
) -> Nil {
  let _watcher =
    process.spawn_unlinked(fn() {
      let monitor = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
      let _down = process.selector_receive_forever(selector)
      socket.notify(home, Died(topic: name, generation: generation))
    })
  Nil
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

/// The socket-level message type: worker results coming home.
///
/// The stamp the issue proposed carries a socket id too. It is redundant
/// here — an envelope travels through one socket's own `Sender`, so it can
/// only arrive at the socket it belongs to.
type Envelope {
  Batch(topic: String, generation: Int, sequence: Int, outcome: Outcome)
  Died(topic: String, generation: Int)
}

/// One worker's answer to one unit of work.
type Outcome {
  Continue(effects: List(socket.Effect))
  Closing(effects: List(socket.Effect))
  StopSocket(reason: socket.StopReason)
}

type Registered {
  Registered(pattern: topic.TopicPattern, handler: channel.Handler)
}

type Worker {
  Worker(
    generation: Int,
    work: process.Subject(Work),
    /// The highest batch sequence applied for this join.
    sequence: Int,
  )
}

type Router {
  Router(
    handlers: List(Registered),
    factory: process.Name(factory_supervisor.Message(Spawn, Report)),
    socket_id: String,
    seed: socket.ConnectSeed,
    self: socket.Sender(Envelope),
    generation: Int,
    live: dict.Dict(String, Worker),
  )
}

/// Build a spike channel system: a factory supervisor for channel workers,
/// then beryl's runtime.
///
/// Start order matters — the runtime's first join looks the factory up by
/// name.
pub fn child_spec(
  config: beryl.Config,
  handlers handlers: List(channel.Handler),
) -> Result(
  #(beryl.Sockets, supervision.ChildSpecification(static_supervisor.Supervisor)),
  beryl.ConfigError,
) {
  let factory = process.new_name("spike_channel_factory")
  let table = table(handlers)

  use #(sockets, runtime) <- result.map(beryl.child_spec(
    config,
    init: fn(info) { init(table, factory, info) },
    update: update,
  ))

  let workers =
    factory_supervisor.worker_child(start_worker)
    |> factory_supervisor.restart_strategy(supervision.Temporary)
    |> factory_supervisor.named(factory)
    |> factory_supervisor.supervised()

  let tree = fn() {
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(workers)
    |> static_supervisor.add(runtime)
    |> static_supervisor.start()
  }

  #(sockets, supervision.supervisor(tree))
}

fn table(handlers: List(channel.Handler)) -> List(Registered) {
  list.map(handlers, fn(handler) {
    Registered(
      pattern: topic.parse_pattern(channel.pattern(handler)),
      handler: handler,
    )
  })
}

fn init(
  handlers: List(Registered),
  factory: process.Name(factory_supervisor.Message(Spawn, Report)),
  info: socket.ConnectInfo(Envelope),
) -> #(Router, List(socket.Effect)) {
  #(
    Router(
      handlers: handlers,
      factory: factory,
      socket_id: info.socket_id,
      seed: info.seed,
      self: info.self,
      generation: 0,
      live: dict.new(),
    ),
    [],
  )
}

fn update(
  router: Router,
  input: socket.Input(Envelope),
) -> socket.Next(Router) {
  case input {
    socket.Join(topic: name, payload: payload, ref: ref) ->
      join(router, name, payload, ref)

    socket.Message(topic: name, event: event, payload: payload, ref: ref) -> {
      cast(
        router,
        name,
        Deliver(channel.Message(
          topic: name,
          event: event,
          payload: payload,
          reply: ref,
        )),
      )
      socket.Next(router, [])
    }

    // Out of spike scope: identical in shape to `Deliver`.
    socket.Binary(topic: _, data: _) -> socket.Next(router, [])

    socket.Closed(topic: name, reason: reason) -> finish(router, name, reason)

    socket.Info(Batch(
      topic: name,
      generation: generation,
      sequence: sequence,
      outcome: outcome,
    )) -> apply(router, name, generation, sequence, outcome)

    socket.Info(Died(topic: name, generation: generation)) ->
      died(router, name, generation)
  }
}

/// Start a worker for an accepted topic, blocking the runtime until the
/// join answers.
fn join(
  router: Router,
  name: String,
  payload: dynamic.Dynamic,
  ref: socket.JoinRef,
) -> socket.Next(Router) {
  case select(router.handlers, name) {
    Error(Nil) ->
      socket.Next(router, [socket.RejectJoin(ref, refusal("unmatched topic"))])
    Ok(#(handler, params)) -> {
      let generation = router.generation + 1
      let router = Router(..router, generation: generation)
      let spawn =
        Spawn(
          handler: handler,
          home: router.self,
          socket_id: router.socket_id,
          seed: router.seed,
          topic: name,
          params: params,
          payload: payload,
          generation: generation,
        )

      case
        factory_supervisor.start_child(
          factory_supervisor.get_by_name(router.factory),
          spawn,
        )
      {
        // A `join` that ran past `join_timeout_ms`. Core has no equivalent
        // — it cannot time a callback out — so this reason is the
        // prototype's own.
        Error(actor.InitTimeout) ->
          socket.Next(router, [socket.RejectJoin(ref, refusal("join timeout"))])

        // A panicking join, which is what core reports as `join crashed`
        // from its rescue boundary. `InitFailed` cannot happen here: the
        // initialiser reports a refusal as data, never as an error.
        Error(actor.InitExited(_)) | Error(actor.InitFailed(_)) ->
          socket.Next(router, [socket.RejectJoin(ref, refusal("join crashed"))])

        Ok(actor.Started(data: Refused(reason: reason), pid: _)) ->
          socket.Next(router, [socket.RejectJoin(ref, reason)])

        Ok(actor.Started(
          pid: pid,
          data: Opened(work: work, reply: reply, effects: accepted),
        )) -> {
          watch(pid, router.self, name, generation)
          let live =
            dict.insert(
              router.live,
              name,
              Worker(generation: generation, work: work, sequence: 0),
            )
          socket.Next(Router(..router, live: live), [
            socket.AcceptJoin(ref, reply),
            ..accepted
          ])
        }
      }
    }
  }
}

fn select(
  handlers: List(Registered),
  name: String,
) -> Result(#(channel.Handler, List(String)), Nil) {
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

fn refusal(reason: String) -> json.Json {
  json.object([#("reason", json.string(reason))])
}

fn cast(router: Router, name: String, work: Work) -> Nil {
  case dict.get(router.live, name) {
    Error(Nil) -> Nil
    Ok(worker) -> process.send(worker.work, work)
  }
}

/// Apply one worker's action batch, after checking its stamp.
///
/// Generation rejects a batch from a superseded join; sequence rejects a
/// replayed or reordered one. Locally the sequence check can never fire —
/// the VM already orders messages between one pair of processes — so it is
/// here for the distributed case and as a live assertion that the
/// invariant holds.
fn apply(
  router: Router,
  name: String,
  generation: Int,
  sequence: Int,
  outcome: Outcome,
) -> socket.Next(Router) {
  case dict.get(router.live, name) {
    Error(Nil) -> socket.Next(router, [])
    Ok(worker) ->
      case worker.generation == generation && sequence > worker.sequence {
        False -> socket.Next(router, [])
        True -> {
          let live =
            dict.insert(router.live, name, Worker(..worker, sequence: sequence))
          let router = Router(..router, live: live)
          case outcome {
            Continue(effects: effects) -> socket.Next(router, effects)
            // The worker stays live until the kick's `Closed` comes back,
            // so termination runs on the one path every ending topic takes.
            Closing(effects: effects) ->
              socket.Next(
                router,
                list.append(effects, [socket.KickTopic(name)]),
              )
            StopSocket(reason: reason) -> socket.Stop(reason)
          }
        }
      }
  }
}

/// A worker exited.
///
/// Its state died with it, so there is no `on_terminate` to run and no way
/// to rebuild the channel: the topic closes and the client must rejoin.
/// Dropping the worker here also keeps the `Closed` this kick produces
/// from waiting on a process that is already gone.
fn died(router: Router, name: String, generation: Int) -> socket.Next(Router) {
  case dict.get(router.live, name) {
    Error(Nil) -> socket.Next(router, [])
    Ok(worker) ->
      case worker.generation == generation {
        False -> socket.Next(router, [])
        True ->
          socket.Next(Router(..router, live: dict.delete(router.live, name)), [
            socket.KickTopic(name),
          ])
      }
  }
}

/// A topic ended: collect the worker's termination actions synchronously,
/// because they have to be lowered inside this turn.
///
/// `ponytail:` a worker that panics in `on_terminate` never replies, so
/// this blocks the shared runtime actor — and therefore every socket on it
/// — for the full `terminate_timeout_ms`. The timeout is the only thing
/// that ends the wait. Upgrade: monitor the worker and select on its
/// `DOWN` alongside the reply, so a dead worker ends the wait immediately.
fn finish(
  router: Router,
  name: String,
  reason: socket.StopReason,
) -> socket.Next(Router) {
  case dict.get(router.live, name) {
    Error(Nil) -> socket.Next(router, [])
    Ok(worker) -> {
      let router = Router(..router, live: dict.delete(router.live, name))
      let reply = process.new_subject()
      process.send(worker.work, Finish(reply: reply, reason: reason))
      case process.receive(reply, terminate_timeout_ms) {
        Ok(effects) -> socket.Next(router, effects)
        // The worker died between the cast and the reply. Its termination
        // actions are lost; the topic still closes.
        Error(Nil) -> socket.Next(router, [])
      }
    }
  }
}
