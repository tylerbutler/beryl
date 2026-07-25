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
import beryl/socket.{AcceptJoin, Join, Next}
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

// ── A trivial named sibling worker used to prove parent/sibling survival ────

fn start_sibling(
  name: process.Name(Nil),
) -> Result(actor.Started(process.Subject(Nil)), actor.StartError) {
  actor.new(0)
  |> actor.on_message(fn(state, _msg) { actor.continue(state) })
  |> actor.named(name)
  |> actor.start
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
      init: h.accepting_init,
      update: h.accepting_update,
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
  process.is_alive(h.runtime_pid(sockets)) |> should.be_true

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
    beryl.start(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  let limiter = limiter_pid(sockets)
  let runtime = h.runtime_pid(sockets)

  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // stop returned only once both subtree workers were down.
  process.is_alive(runtime) |> should.be_false
  process.is_alive(limiter) |> should.be_false
}

// ── the limiter survives a runtime crash but stops with the subtree ─────────

pub fn limiter_survives_runtime_restart_test() {
  let assert Ok(sockets) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  let limiter = limiter_pid(sockets)
  let old_runtime = h.runtime_pid(sockets)

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
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
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
  process.kill(h.runtime_pid(sockets))

  // The owned connection observed the runtime's death and closed itself.
  process.receive(closed, 2000) |> should.equal(Ok(Nil))
}

// ── an update crash closes the affected socket through its close callback ───

fn capturing_init(
  senders: process.Subject(socket.Sender(Nil)),
) -> fn(socket.ConnectInfo(Nil)) -> #(Nil, List(socket.Effect)) {
  fn(info: socket.ConnectInfo(Nil)) {
    process.send(senders, info.self)
    #(Nil, [])
  }
}

fn crashing_update(model: Nil, ev: socket.Input(Nil)) -> socket.Next(Nil, Nil) {
  case ev {
    Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
    socket.Info(_) -> panic as "boom"
    _ -> Next(model, [])
  }
}

pub fn update_crash_runs_socket_close_callback_test() {
  let senders = process.new_subject()
  let assert Ok(sockets) =
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: capturing_init(senders),
      update: crashing_update,
    )

  let closed = process.new_subject()
  transport.socket_connected(
    sockets: sockets,
    socket_id: "s1",
    send: fn(_message) { Ok(Nil) },
    send_binary: fn(_data) { Ok(Nil) },
    seed: socket.empty_seed(),
  )
  transport.register_closer(sockets: sockets, socket_id: "s1", close: fn() {
    process.send(closed, Nil)
  })
  let assert Ok(sender) = process.receive(senders, 1000)

  // Drive an app-info event into the crashing update; the runtime rescues the
  // crash, tears the socket down, and runs its registered close callback.
  socket.notify(sender, Nil)

  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  // The runtime itself survives the rescued crash and keeps serving.
  process.is_alive(h.runtime_pid(sockets)) |> should.be_true
}

// ── transport connection ownership status ───────────────────────────────────

pub fn connection_owner_reports_alive_when_running_test() {
  let assert Ok(sockets) =
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  case transport.connection_owner(sockets) {
    transport.OwnerAlive(pid) -> pid |> should.equal(h.runtime_pid(sockets))
    _ -> should.fail()
  }

  let assert Ok(_) = beryl.stop(sockets)
}

pub fn connection_owner_unavailable_before_start_test() {
  let assert Ok(#(sockets, _spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
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

fn not_running(sockets: beryl.Sockets) -> Bool {
  case beryl.app_runtime_pid(sockets) {
    Ok(_) -> False
    Error(Nil) -> True
  }
}

// ── the embedded subtree dies with the application root ─────────────────────

pub fn application_root_shutdown_tears_down_beryl_subtree_test() {
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: h.accepting_init,
      update: h.accepting_update,
    )
  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()
  test_helpers.wait_until(
    fn() { beryl.app_runtime_pid(sockets) |> to_bool },
    2000,
    10,
  )
  let runtime = h.runtime_pid(sockets)
  let limiter = limiter_pid(sockets)

  // The application root goes down; the embedded Beryl subtree, linked under
  // it, is torn down with it (unlink first so the test process survives).
  process.unlink(root.pid)
  process.kill(root.pid)

  test_helpers.wait_until(fn() { !process.is_alive(runtime) }, 2000, 10)
  process.is_alive(runtime) |> should.be_false
  process.is_alive(limiter) |> should.be_false
  beryl.app_runtime_pid(sockets) |> should.be_error
}

// ── a partial startup failure leaks no Beryl processes ──────────────────────

pub fn partial_startup_failure_tears_down_beryl_subtree_test() {
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  // A sibling that always fails to start. The supervisor tears down the
  // already-started Beryl subtree and exits, so the doomed startup is run in
  // an unlinked child process to keep its failure signal off the test.
  let failing =
    supervision.worker(fn() -> Result(
      actor.Started(process.Subject(Nil)),
      actor.StartError,
    ) {
      Error(actor.InitFailed("intentional"))
    })

  process.spawn_unlinked(fn() {
    let _ =
      static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.add(beryl_spec)
      |> static_supervisor.add(failing)
      |> static_supervisor.start()
    Nil
  })

  // Whether or not the doomed supervisor reported an error, no Beryl runtime
  // or limiter is left running.
  test_helpers.wait_until(fn() { not_running(sockets) }, 3000, 20)
  beryl.app_runtime_pid(sockets) |> should.be_error
  beryl.app_limiter_pid(sockets) |> should.be_error
}

// ── stop waits for the runtime even with no limiter ─────────────────────────

pub fn stop_without_limiter_waits_for_runtime_teardown_test() {
  let assert Ok(sockets) =
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  // No connection limit is configured, so there is no limiter in the subtree.
  beryl.app_limiter_pid(sockets) |> should.be_error
  let runtime = h.runtime_pid(sockets)

  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // stop still waited for the runtime itself to terminate before returning.
  process.is_alive(runtime) |> should.be_false
}

// ── stop leaves no registered name or live process behind ───────────────────

pub fn stop_leaves_no_registered_name_or_process_test() {
  let assert Ok(sockets) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(3),
      init: h.accepting_init,
      update: h.accepting_update,
    )
  let runtime = h.runtime_pid(sockets)
  let limiter = limiter_pid(sockets)

  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // Both processes are gone and their registered names no longer resolve.
  process.is_alive(runtime) |> should.be_false
  process.is_alive(limiter) |> should.be_false
  beryl.app_runtime_pid(sockets) |> should.be_error
  beryl.app_limiter_pid(sockets) |> should.be_error
  // The system is fully gone: a fresh connection cannot be admitted.
  beryl.acquire_connection_slot(sockets, "1.2.3.4") |> should.be_error
}
