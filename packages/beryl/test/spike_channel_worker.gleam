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
//// - Each socket starts **its own** `factory_supervisor` in `init`, linked
////   to its own socket actor, and one `Temporary` worker per accepted join
////   runs under it. Temporary is the point: a worker whose join and
////   authorization state died must not be restarted behind the client's
////   back. Per-socket is round 2's change (see below) — round 1 used one
////   globally named factory for the whole server.
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
//// ## Round 2, on the per-socket runtime (#334)
////
//// Round 1 ran on the shared runtime actor and concluded that #337 was
//// downstream of #334. Round 2 re-ran it on the per-socket runtime and
//// claimed what that made available:
////
//// - **A supervisor per socket**, started by and linked to the socket's own
////   actor. Joins no longer serialise across sockets through one
////   `supervisor:start_child`, and no worker outlives its connection. The
////   global name and the `OneForAll` runtime coupling are both gone.
//// - **One watcher per socket** instead of one per worker (see
////   `start_watcher`). This was never a #334 cost; round 1 over-booked it.
////
//// ## Known ceilings
////
//// `ponytail:` spike-scope cuts — no backpressure, no binary frames, and no
//// pattern validation. A *blocking* `on_terminate` still holds `finish` for
//// `terminate_timeout_ms`, but #334 confines that to its own socket for
//// free.
////
//// One thing is not a cut and is not a topology problem either: a close
//// races the worker's own in-flight batch, and the batch loses (see
//// `apply`). Round 1 expected #334 to fix it. It does not, and no drain
//// can — see `a_reply_ref_is_dead_by_the_closed_turn_test`. Findings are in
//// `docs/spikes/0337-process-per-channel-round-2.md`.

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
/// abandoned and the join rejected. This is the *only* bound on the wait:
/// `supervisor:start_child` calls with `infinity`, so the runtime actor is
/// blocked for this long in the worst case. A real design would want it
/// much lower.
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

/// What the per-socket watcher is told to monitor.
type Watch {
  Watch(pid: process.Pid, topic: String, generation: Int)
}

/// Notify the socket when any of its workers exits.
///
/// **One process per socket, not per channel.** Round 1 spawned a watcher
/// per worker and booked that as a cost #334 would repay. It was never a
/// #334 cost: `init` has always run once per socket and `info.self` has
/// always been that socket's own `Sender`, so a single watcher holding a
/// monitor per worker was available on the shared runtime too. What #334
/// does add is that the watcher can be started *by* the socket's own
/// process, so it dies with the socket instead of outliving it.
fn start_watcher(home: socket.Sender(Envelope)) -> process.Subject(Watch) {
  let ready = process.new_subject()
  let _pid =
    process.spawn(fn() {
      let inbox = process.new_subject()
      process.send(ready, inbox)
      watch_loop(inbox, home, dict.new())
    })
  let assert Ok(inbox) = process.receive(ready, 1000)
    as "the socket's watcher started"
  inbox
}

fn watch_loop(
  inbox: process.Subject(Watch),
  home: socket.Sender(Envelope),
  watched: dict.Dict(process.Pid, #(String, Int)),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(inbox, Ok)
    |> process.select_monitors(Error)
  case process.selector_receive_forever(selector) {
    Ok(Watch(pid: pid, topic: name, generation: generation)) -> {
      let _monitor = process.monitor(pid)
      watch_loop(inbox, home, dict.insert(watched, pid, #(name, generation)))
    }
    Error(down) ->
      case down {
        process.ProcessDown(pid: pid, ..) -> {
          case dict.get(watched, pid) {
            Ok(#(name, generation)) ->
              socket.notify(home, Died(topic: name, generation: generation))
            Error(Nil) -> Nil
          }
          watch_loop(inbox, home, dict.delete(watched, pid))
        }
        _ -> watch_loop(inbox, home, watched)
      }
  }
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
    /// Kept so `finish` can monitor the worker rather than trust that it is
    /// still alive.
    pid: process.Pid,
    /// The highest batch sequence applied for this join.
    sequence: Int,
  )
}

type Router {
  Router(
    handlers: List(Registered),
    /// This socket's own worker supervisor, started in `init` and linked
    /// to the socket's process.
    factory: factory_supervisor.Supervisor(Spawn, Report),
    /// This socket's single watcher (see `start_watcher`).
    watcher: process.Subject(Watch),
    socket_id: String,
    seed: socket.ConnectSeed,
    self: socket.Sender(Envelope),
    generation: Int,
    live: dict.Dict(String, Worker),
  )
}

/// Build a spike channel system.
///
/// Round 1 needed a supervision tree here: one globally named factory
/// supervisor for every worker on every socket, wrapped with the runtime in
/// `OneForAll` so a restarted runtime could not orphan them. Post-#334 the
/// socket actor owns its own workers, so this is `beryl.child_spec` and
/// nothing else — the whole tree, the global name, and the `OneForAll`
/// coupling are gone.
pub fn child_spec(
  config: beryl.Config,
  handlers handlers: List(channel.Handler),
) -> Result(
  #(beryl.Sockets, supervision.ChildSpecification(static_supervisor.Supervisor)),
  beryl.ConfigError,
) {
  let table = table(handlers)
  beryl.child_spec(config, init: fn(info) { init(table, info) }, update: update)
}

fn table(handlers: List(channel.Handler)) -> List(Registered) {
  list.map(handlers, fn(handler) {
    Registered(
      pattern: topic.parse_pattern(channel.pattern(handler)),
      handler: handler,
    )
  })
}

/// Start this socket's worker supervisor and watcher.
///
/// Both are linked to the socket's own process, which is what #334 bought:
/// worker lifetime is now bounded by the connection rather than by a global
/// tree, and no worker can outlive the socket that joined it.
fn init(
  handlers: List(Registered),
  info: socket.ConnectInfo(Envelope),
) -> #(Router, List(socket.Effect)) {
  let assert Ok(actor.Started(data: factory, pid: _)) =
    factory_supervisor.worker_child(start_worker)
    |> factory_supervisor.restart_strategy(supervision.Temporary)
    |> factory_supervisor.start()
    as "the socket's worker supervisor started"

  #(
    Router(
      handlers: handlers,
      factory: factory,
      watcher: start_watcher(info.self),
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

      case factory_supervisor.start_child(router.factory, spawn) {
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
          process.send(
            router.watcher,
            Watch(pid: pid, topic: name, generation: generation),
          )
          let live =
            dict.insert(
              router.live,
              name,
              Worker(generation: generation, work: work, pid: pid, sequence: 0),
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
///
/// **A close beats a batch it should have followed.** A batch travels the
/// slow path (worker → socket `Sender` → this turn) while `finish` answers
/// on a direct subject, so a client that pushes and then leaves can have
/// its reply produced, reported, and then dropped here — the topic is gone
/// from `live` by the time the batch is read.
///
/// Round 1 read this as a missing drain that #334 would supply. It is not.
/// Core deletes a topic's `pending_reply_refs` *before* it delivers
/// `Closed`, so the raced reply is unanswerable from the closing turn no
/// matter which process drains what — with no workers in the picture at
/// all, `a_reply_ref_is_dead_by_the_closed_turn_test` loses the same reply.
/// Preserving it needs core to hold the close until the worker is
/// quiescent, which means core has to own the worker.
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
/// The wait selects on the worker's `DOWN` alongside its reply, so a worker
/// that is already dead — or that panics inside `on_terminate` — ends the
/// wait at once instead of holding the shared runtime actor, and every
/// socket on it, for the full timeout.
///
/// `ponytail:` an `on_terminate` that *blocks* rather than dies still holds
/// this wait for up to `terminate_timeout_ms`. On the per-socket runtime
/// that stalls only its own connection — pinned by
/// `a_blocking_terminate_stalls_only_its_own_socket_test`, which needed no
/// change here to pass.
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
      let monitor = process.monitor(worker.pid)
      process.send(worker.work, Finish(reply: reply, reason: reason))
      let answer =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
        |> process.selector_receive(terminate_timeout_ms)
      // Flushes a `DOWN` that raced the reply, so none is left for the
      // runtime actor's own selector to trip over.
      process.demonitor_process(monitor)
      case answer {
        Ok(Ok(effects)) -> socket.Next(router, effects)
        // The worker died before replying, or never replied at all. Its
        // termination actions are lost; the topic still closes.
        Ok(Error(Nil)) | Error(Nil) -> socket.Next(router, [])
      }
    }
  }
}
