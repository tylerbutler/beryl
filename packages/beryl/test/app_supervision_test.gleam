//// Nested-subtree lifecycle semantics for app-side dispatch systems
//// (ADR 0002 phase 2, task 2): the Beryl runtime is a significant transient
//// child under a one-for-one subtree with `auto_shutdown`, so a graceful
//// `beryl.stop` tears down only Beryl's subtree (runtime + optional limiter)
//// without restarting under, or disturbing, an embedding application's parent
//// and sibling children. A runtime crash restarts dispatch under the same
//// handle while the limiter survives, and connection owners that monitor the
//// accepting runtime close when it dies.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Next}
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleeunit
import gleeunit/should
import test_helpers

pub fn main() {
  gleeunit.main()
}

// A minimal app system that accepts every join.
fn accepting_init(_info: event.ConnectInfo(Nil)) -> #(Nil, List(event.Effect)) {
  #(Nil, [])
}

fn accepting_update(model: Nil, ev: event.Event(Nil)) -> event.Next(Nil, Nil) {
  case ev {
    Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
    _ -> Next(model, [])
  }
}

// ── A trivial named sibling worker used to prove parent/sibling survival ────

fn start_sibling(
  name: process.Name(Nil),
) -> Result(actor.Started(process.Subject(Nil)), actor.StartError) {
  actor.new(0)
  |> actor.on_message(fn(state, _msg) { actor.continue(state) })
  |> actor.named(name)
  |> actor.start
}

fn runtime_pid(sockets: beryl.Sockets) -> process.Pid {
  let assert Ok(pid) = beryl.app_runtime_pid(sockets)
  pid
}

fn limiter_pid(sockets: beryl.Sockets) -> process.Pid {
  let assert Ok(pid) = beryl.app_limiter_pid(sockets)
  pid
}

// ── stop targets only the Beryl subtree ─────────────────────────────────────

pub fn stop_shuts_down_only_beryl_subtree_test() {
  let sibling_name = process.new_name("sibling_worker")
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: accepting_init,
      update: accepting_update,
    )

  let sibling_spec = supervision.worker(fn() { start_sibling(sibling_name) })

  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.add(sibling_spec)
    |> static_supervisor.start()

  // Everything is up.
  test_helpers.wait_until(
    fn() { beryl.app_runtime_pid(sockets) |> to_bool },
    2000,
    10,
  )
  let sibling_subject = process.named_subject(sibling_name)
  let assert Ok(sibling) = process.subject_owner(sibling_subject)
  let assert Ok(_) = beryl.app_limiter_pid(sockets)
  process.is_alive(runtime_pid(sockets)) |> should.be_true

  // Stop only the Beryl subtree.
  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // Beryl's runtime and limiter are gone and stay gone (the parent must not
  // restart the transient subtree after a graceful stop).
  beryl.app_runtime_pid(sockets) |> should.be_error
  beryl.app_limiter_pid(sockets) |> should.be_error
  process.sleep(100)
  beryl.app_runtime_pid(sockets) |> should.be_error

  // The sibling child and the application's root supervisor are untouched.
  process.is_alive(sibling) |> should.be_true
  process.is_alive(root.pid) |> should.be_true
}

// ── stop waits for the whole subtree (runtime + limiter) to terminate ───────

pub fn stop_waits_for_subtree_teardown_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: accepting_init,
      update: accepting_update,
    )

  let limiter = limiter_pid(sockets)
  let runtime = runtime_pid(sockets)

  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // stop returned only once both subtree workers were down.
  process.is_alive(runtime) |> should.be_false
  process.is_alive(limiter) |> should.be_false
}

// ── the limiter survives a runtime crash but stops with the subtree ─────────

pub fn limiter_survives_runtime_restart_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: accepting_init,
      update: accepting_update,
    )

  let limiter = limiter_pid(sockets)
  let old_runtime = runtime_pid(sockets)

  // Crash the runtime abnormally; the transient significant child restarts.
  process.kill(old_runtime)

  test_helpers.wait_until(
    fn() {
      case beryl.app_runtime_pid(sockets) {
        Ok(pid) -> pid != old_runtime
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  // A runtime restart does not restart the limiter: same pid, still serving.
  limiter_pid(sockets) |> should.equal(limiter)
  process.is_alive(limiter) |> should.be_true

  // Stopping the subtree still tears the (surviving) limiter down.
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  process.is_alive(limiter) |> should.be_false
}

// ── a runtime crash closes connections that monitor the accepting runtime ──

pub fn runtime_crash_closes_owned_connection_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: accepting_init,
      update: accepting_update,
    )

  let closed = process.new_subject()

  // Simulate a transport connection process: it monitors the runtime that
  // accepted it (via the transport SPI) and closes when that runtime dies.
  let _conn =
    process.spawn(fn() {
      case transport.connection_owner(sockets) {
        transport.OwnerAlive(pid) -> {
          let mon = process.monitor(pid)
          let selector =
            process.new_selector()
            |> process.select_specific_monitor(mon, fn(_down) { Nil })
          let _ = process.selector_receive(selector, 2000)
          process.send(closed, Nil)
        }
        _ -> Nil
      }
    })

  // Give the connection process time to install its monitor, then crash.
  process.sleep(50)
  process.kill(runtime_pid(sockets))

  // The owned connection observed the runtime's death and closed itself.
  process.receive(closed, 2000) |> should.equal(Ok(Nil))
}

// ── an update crash closes the affected socket through its close callback ───

fn capturing_init(
  senders: process.Subject(event.Sender(Nil)),
) -> fn(event.ConnectInfo(Nil)) -> #(Nil, List(event.Effect)) {
  fn(info: event.ConnectInfo(Nil)) {
    process.send(senders, info.self)
    #(Nil, [])
  }
}

fn crashing_update(model: Nil, ev: event.Event(Nil)) -> event.Next(Nil, Nil) {
  case ev {
    Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
    event.Info(_) -> panic as "boom"
    _ -> Next(model, [])
  }
}

pub fn update_crash_runs_socket_close_callback_test() {
  let senders = process.new_subject()
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: capturing_init(senders),
      update: crashing_update,
    )

  let closed = process.new_subject()
  transport.socket_connected(
    channels: sockets,
    socket_id: "s1",
    send: fn(_message) { Ok(Nil) },
    send_binary: fn(_data) { Ok(Nil) },
    assigns: Nil,
    seed: event.empty_seed(),
  )
  transport.register_closer(channels: sockets, socket_id: "s1", close: fn() {
    process.send(closed, Nil)
  })
  let assert Ok(sender) = process.receive(senders, 1000)

  // Drive an app-info event into the crashing update; the runtime rescues the
  // crash, tears the socket down, and runs its registered close callback.
  event.notify(sender, Nil)

  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  // The runtime itself survives the rescued crash and keeps serving.
  process.is_alive(runtime_pid(sockets)) |> should.be_true
}

// ── transport connection ownership status ───────────────────────────────────

pub fn connection_owner_reports_alive_when_running_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: accepting_init,
      update: accepting_update,
    )

  case transport.connection_owner(sockets) {
    transport.OwnerAlive(pid) -> pid |> should.equal(runtime_pid(sockets))
    _ -> should.fail()
  }

  let assert Ok(_) = beryl.stop(sockets)
}

pub fn connection_owner_unavailable_before_start_test() {
  let assert Ok(#(sockets, _spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: accepting_init,
      update: accepting_update,
    )

  // The runtime is not running yet: a new connection cannot be owned, so the
  // transport must refuse it rather than admit a dead socket.
  transport.connection_owner(sockets)
  |> should.equal(transport.OwnerUnavailable)
}

fn to_bool(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}
