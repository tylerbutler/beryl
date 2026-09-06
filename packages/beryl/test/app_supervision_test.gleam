//// Nested-subtree lifecycle semantics for app-side dispatch systems
//// (ADR 0002 phase 2, task 2): the beryl runtime is a significant transient
//// child under a one-for-one subtree with `auto_shutdown`, so a graceful
//// `beryl.stop` tears down only beryl's subtree (runtime + optional limiter)
//// without restarting under, or disturbing, an embedding application's parent
//// and sibling children. A runtime crash restarts dispatch under the same
//// handle while the limiter survives, and connection owners that monitor the
//// accepting runtime close when it dies.

import app_test_helper
import beryl
import beryl/snapshot
import beryl/socket.{AcceptJoin, Broadcast, Join, Next}
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleeunit/should
import test_helper

type Gate

@external(erlang, "beryl_supervisor_test_ffi", "gate_new")
fn new_gate() -> Gate

@external(erlang, "beryl_supervisor_test_ffi", "gate_wait")
fn wait_for_gate(gate: Gate) -> Nil

@external(erlang, "beryl_supervisor_test_ffi", "gate_release")
fn release_gate(gate: Gate) -> Nil

@external(erlang, "beryl_supervisor_test_ffi", "active_child_count")
fn active_child_count(supervisor: process.Pid) -> Int

// ── A trivial named sibling worker used to prove parent/sibling survival ────

fn start_sibling(
  name: process.Name(Nil),
) -> Result(actor.Started(process.Subject(Nil)), actor.StartError) {
  actor.new(0)
  |> actor.on_message(fn(state, _message) { actor.continue(state) })
  |> actor.named(name)
  |> actor.start
}

fn limiter_pid(sockets: beryl.Sockets) -> process.Pid {
  let assert Ok(pid) = beryl.app_limiter_pid(sockets)
  pid
}

fn admit(
  sockets: beryl.Sockets,
  owner: process.Pid,
  socket_id: String,
  close: fn() -> Nil,
) -> Result(Nil, Nil) {
  transport.admit_socket(
    sockets: sockets,
    owner: owner,
    socket_id: socket_id,
    send: fn(_message) { Ok(Nil) },
    send_binary: fn(_data) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: close,
  )
}

// ── stop targets only the beryl subtree ─────────────────────────────────────

pub fn stop_shuts_down_only_beryl_subtree_test() -> Nil {
  let sibling_name = process.new_name("sibling_worker")
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  let sibling_spec = supervision.worker(fn() { start_sibling(sibling_name) })

  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.add(sibling_spec)
    |> static_supervisor.start()

  // Everything is up.
  test_helper.wait_until(
    fn() { beryl.app_runtime_pid(sockets) |> result.is_ok },
    2000,
    10,
  )
  let sibling_subject = process.named_subject(sibling_name)
  let assert Ok(sibling) = process.subject_owner(sibling_subject)
  let assert Ok(_) = beryl.app_limiter_pid(sockets)
  process.is_alive(app_test_helper.runtime_pid(sockets)) |> should.be_true

  // Stop only the beryl subtree.
  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // beryl's runtime and limiter are gone and stay gone (the parent must not
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

pub fn stop_waits_for_subtree_teardown_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  let limiter = limiter_pid(sockets)
  let runtime = app_test_helper.runtime_pid(sockets)

  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // stop returned only once both subtree workers were down.
  process.is_alive(runtime) |> should.be_false
  process.is_alive(limiter) |> should.be_false
}

// ── the limiter survives a runtime crash but stops with the subtree ─────────

pub fn limiter_survives_runtime_restart_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_connection_rate_per_ip(per_second: 1, burst: 1),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  let limiter = limiter_pid(sockets)
  let old_runtime = app_test_helper.runtime_pid(sockets)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.10")
  transport.release_connection_slot(permit)

  // Crash the runtime abnormally; the transient significant child restarts.
  process.kill(old_runtime)

  // The exhausted IP bucket remains live while dispatch restarts.
  transport.acquire_connection_slot(sockets, "192.0.2.10")
  |> should.be_error

  test_helper.wait_until(
    fn() {
      case beryl.app_runtime_pid(sockets) {
        Ok(pid) -> pid != old_runtime
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  // A runtime restart does not restart the limiter: same pid and rate state.
  limiter_pid(sockets) |> should.equal(limiter)
  process.is_alive(limiter) |> should.be_true

  // Stopping the subtree still tears the (surviving) limiter down.
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  process.is_alive(limiter) |> should.be_false
}

pub fn limiter_restart_preserves_connection_state_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(1)
        |> beryl.with_connection_rate_per_ip(per_second: 1, burst: 2),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  let rate_ip = "192.0.2.20"
  let assert Ok(first) = transport.acquire_connection_slot(sockets, rate_ip)
  transport.release_connection_slot(first)
  let assert Ok(second) = transport.acquire_connection_slot(sockets, rate_ip)
  transport.release_connection_slot(second)

  let count_ip = "192.0.2.21"
  let assert Ok(counted) = transport.acquire_connection_slot(sockets, count_ip)
  transport.bind_connection_slot(counted)

  let old_limiter = limiter_pid(sockets)
  process.kill(old_limiter)
  test_helper.wait_until(
    fn() {
      case beryl.app_limiter_pid(sockets) {
        Ok(pid) -> pid != old_limiter
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  // The exhausted bucket and bound live count both survive worker replacement.
  transport.acquire_connection_slot(sockets, rate_ip) |> should.be_error
  transport.acquire_connection_slot(sockets, count_ip) |> should.be_error

  // The replacement remonitors holders and still handles explicit release.
  transport.release_connection_slot(counted)
  transport.acquire_connection_slot(sockets, count_ip) |> should.be_ok

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

// ── a runtime crash while stopping does not poison later lifecycle events ──

pub fn runtime_crash_during_stop_recovers_and_second_stop_succeeds_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  let recovered_runtime = crash_runtime_during_stop(sockets)
  process.is_alive(recovered_runtime) |> should.be_true

  beryl.stop(sockets) |> should.equal(Ok(Nil))
  process.is_alive(recovered_runtime) |> should.be_false
  beryl.app_runtime_pid(sockets) |> should.be_error
}

pub fn unresponsive_socket_stop_returns_timeout_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let gate = new_gate()
  let stop_entered = process.new_subject()
  let stop_result = process.new_subject()

  admit(sockets, app_test_helper.runtime_pid(sockets), "stuck-stop", fn() {
    process.send(stop_entered, Nil)
    wait_for_gate(gate)
  })
  |> should.equal(Ok(Nil))

  let _stopper =
    process.spawn(fn() { process.send(stop_result, beryl.stop(sockets)) })

  process.receive(stop_entered, 1000) |> should.equal(Ok(Nil))
  process.receive(stop_result, 4000)
  |> should.equal(Ok(Error(beryl.StopTimeout)))
  release_gate(gate)
}

pub fn runtime_crash_during_stop_does_not_hide_later_exhaustion_test() -> Nil {
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  test_helper.wait_until(
    fn() { beryl.app_runtime_pid(sockets) |> result.is_ok },
    2000,
    10,
  )
  let original_limiter = limiter_pid(sockets)
  let runtime2 = crash_runtime_during_stop(sockets)

  // The crash during stop counts as the first failure in the nested
  // supervisor's restart window. Three more rapid crashes must therefore
  // exhaust it and restart the whole beryl subtree under the application root.
  process.kill(runtime2)
  let runtime3 = wait_for_new_runtime(sockets, runtime2)
  process.kill(runtime3)
  let runtime4 = wait_for_new_runtime(sockets, runtime3)
  process.kill(runtime4)

  test_helper.wait_until(
    fn() {
      case beryl.app_limiter_pid(sockets), beryl.app_runtime_pid(sockets) {
        Ok(limiter), Ok(runtime) ->
          limiter != original_limiter && runtime != runtime4
        Ok(_), Error(_) | Error(_), Ok(_) | Error(_), Error(_) -> False
      }
    },
    3000,
    10,
  )

  process.is_alive(root.pid) |> should.be_true
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

fn crash_runtime_during_stop(sockets: beryl.Sockets) -> process.Pid {
  let gate = new_gate()
  let stop_entered = process.new_subject()
  let stop_result = process.new_subject()
  let old_runtime = app_test_helper.runtime_pid(sockets)

  admit(
    sockets,
    app_test_helper.runtime_pid(sockets),
    "crash-during-stop",
    fn() {
      process.send(stop_entered, Nil)
      wait_for_gate(gate)
    },
  )
  |> should.equal(Ok(Nil))

  let _stopper =
    process.spawn(fn() { process.send(stop_result, beryl.stop(sockets)) })

  process.receive(stop_entered, 1000) |> should.equal(Ok(Nil))
  process.kill(old_runtime)
  process.receive(stop_result, 2000)
  |> should.equal(Ok(Error(beryl.StopTimeout)))

  wait_for_new_runtime(sockets, old_runtime)
}

// ── restart-intensity exhaustion is escalated to the application root ──────

pub fn restart_intensity_exhaustion_restarts_outer_subtree_test() -> Nil {
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  test_helper.wait_until(
    fn() { beryl.app_runtime_pid(sockets) |> result.is_ok },
    2000,
    10,
  )

  let original_limiter = limiter_pid(sockets)
  let runtime1 = app_test_helper.runtime_pid(sockets)
  process.kill(runtime1)
  let runtime2 = wait_for_new_runtime(sockets, runtime1)
  process.kill(runtime2)
  let runtime3 = wait_for_new_runtime(sockets, runtime2)
  process.kill(runtime3)
  let runtime4 = wait_for_new_runtime(sockets, runtime3)

  // The fourth rapid crash exceeds the nested supervisor's intensity of
  // three. The lifecycle wrapper converts its `shutdown` into an abnormal
  // exit, so the application root restarts the whole subtree.
  process.kill(runtime4)
  test_helper.wait_until(
    fn() {
      case beryl.app_limiter_pid(sockets), beryl.app_runtime_pid(sockets) {
        Ok(limiter), Ok(runtime) ->
          limiter != original_limiter && runtime != runtime4
        Ok(_), Error(_) | Error(_), Ok(_) | Error(_), Error(_) -> False
      }
    },
    3000,
    10,
  )

  let recovered_runtime = app_test_helper.runtime_pid(sockets)
  limiter_pid(sockets) |> should.not_equal(original_limiter)

  // The original name-backed Sockets handle is re-registered and usable.
  admit(sockets, app_test_helper.runtime_pid(sockets), "after-exhaustion", fn() {
    Nil
  })
  |> should.equal(Ok(Nil))
  process.is_alive(recovered_runtime) |> should.be_true

  // Intentional stop still terminates normally, so the outer transient child
  // stays down instead of undoing beryl.stop.
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  process.sleep(100)
  beryl.app_runtime_pid(sockets) |> should.be_error
  beryl.app_limiter_pid(sockets) |> should.be_error
  process.is_alive(root.pid) |> should.be_true
}

fn wait_for_new_runtime(
  sockets: beryl.Sockets,
  old_runtime: process.Pid,
) -> process.Pid {
  test_helper.wait_until(
    fn() {
      case beryl.app_runtime_pid(sockets) {
        Ok(pid) -> pid != old_runtime
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )
  app_test_helper.runtime_pid(sockets)
}

// ── a runtime crash closes connections that monitor the accepting runtime ──

pub fn runtime_crash_closes_owned_connection_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  let closed = process.new_subject()
  let ready = process.new_subject()

  // Simulate a transport connection process: it monitors the runtime that
  // accepted it before registration and closes when that exact runtime dies.
  let _connection =
    process.spawn(fn() {
      case transport.runtime_pid(sockets) {
        Ok(pid) -> {
          let monitor = process.monitor(pid)
          let selector =
            process.new_selector()
            |> process.select_specific_monitor(monitor, fn(_down) { Nil })
          process.send(ready, Nil)
          let _ = process.selector_receive(selector, 2000)
          process.send(closed, Nil)
        }
        Error(_) -> Nil
      }
    })

  // Wait for the monitor-installation handshake rather than sleeping.
  process.receive(ready, 1000) |> should.equal(Ok(Nil))
  process.kill(app_test_helper.runtime_pid(sockets))

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

fn crashing_update(model: Nil, event: socket.Input(Nil)) -> socket.Next(Nil) {
  case event {
    Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
    socket.Info(_) -> panic as "boom"
    socket.Message(..) | socket.Binary(..) | socket.Closed(..) ->
      Next(model, [])
  }
}

pub fn update_crash_runs_socket_close_callback_test() -> Nil {
  let senders = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: capturing_init(senders),
      update: crashing_update,
    )

  let closed = process.new_subject()
  let owner = app_test_helper.runtime_pid(sockets)
  admit(sockets, owner, "s1", fn() { process.send(closed, Nil) })
  |> should.equal(Ok(Nil))
  let assert Ok(sender) = process.receive(senders, 1000)

  // Drive an app-info event into the crashing update; the runtime rescues the
  // crash, tears the socket down, and runs its registered close callback.
  socket.notify(sender, Nil)

  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  // The runtime itself survives the rescued crash and keeps serving.
  process.is_alive(app_test_helper.runtime_pid(sockets)) |> should.be_true
}

pub fn failed_registration_closes_connection_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: socket.ConnectInfo(Nil)) { panic as "init failed" },
      update: app_test_helper.accepting_update,
    )
  let closed = process.new_subject()

  admit(sockets, app_test_helper.runtime_pid(sockets), "failed-init", fn() {
    process.send(closed, Nil)
  })
  |> should.be_error

  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  process.is_alive(app_test_helper.runtime_pid(sockets)) |> should.be_true
}

pub fn stale_runtime_owner_cannot_register_with_successor_test() -> Nil {
  let initialized = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info: socket.ConnectInfo(Nil)) {
        process.send(initialized, info.socket_id)
        #(Nil, [])
      },
      update: app_test_helper.accepting_update,
    )
  let assert Ok(old_runtime) = transport.runtime_pid(sockets)
  let monitor = process.monitor(old_runtime)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })

  process.kill(old_runtime)
  process.selector_receive(selector, 2000) |> should.equal(Ok(Nil))
  test_helper.wait_until(
    fn() {
      case beryl.app_runtime_pid(sockets) {
        Ok(pid) -> pid != old_runtime
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  let closed = process.new_subject()
  admit(sockets, old_runtime, "stale-owner", fn() { process.send(closed, Nil) })
  |> should.be_error
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  process.receive(initialized, 100) |> should.be_error
  process.is_alive(app_test_helper.runtime_pid(sockets)) |> should.be_true
}

pub fn timed_out_admission_cannot_register_or_apply_init_effects_test() -> Nil {
  let initialized = process.new_subject()
  let init_entered = process.new_subject()
  let gate = new_gate()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(1),
      init: fn(info: socket.ConnectInfo(Nil)) {
        case info.socket_id {
          "late" -> {
            process.send(init_entered, Nil)
            wait_for_gate(gate)
            #(Nil, [
              Broadcast("room:a", "late_init_effect", json.object([])),
            ])
          }
          _ -> {
            process.send(initialized, #(info.socket_id, info.self))
            #(Nil, [])
          }
        }
      },
      update: fn(model, input) {
        case input {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          socket.Message(..)
          | socket.Binary(..)
          | socket.Closed(..)
          | socket.Info(..) -> Next(model, [])
        }
      },
    )

  let observer_frames = app_test_helper.connect(sockets, "observer")
  let assert Ok(#("observer", _observer)) = process.receive(initialized, 1000)
  app_test_helper.join(
    sockets,
    "observer",
    "room:a",
    "jr-observer",
    "r-observer",
  )
  let _join_reply = app_test_helper.recv(observer_frames)

  let admission_result = process.new_subject()
  let connection_closed = process.new_subject()
  let late_frames = process.new_subject()
  let _connection =
    process.spawn(fn() {
      let assert Ok(permit) =
        transport.acquire_connection_slot(sockets, "203.0.113.10")
      transport.bind_connection_slot(permit)
      let assert Ok(owner) = transport.runtime_pid(sockets)
      let result =
        transport.admit_socket(
          sockets: sockets,
          owner: owner,
          socket_id: "late",
          send: fn(frame) {
            process.send(late_frames, frame)
            Ok(Nil)
          },
          send_binary: fn(_data) { Ok(Nil) },
          codec: None,
          seed: socket.empty_seed(),
          close: fn() {
            transport.release_connection_slot(permit)
            process.send(connection_closed, Nil)
          },
        )
      process.send(admission_result, result)
    })

  process.receive(init_entered, 1000) |> should.equal(Ok(Nil))
  process.receive(admission_result, 1500)
  |> should.equal(Ok(Error(Nil)))
  process.receive(connection_closed, 1000) |> should.equal(Ok(Nil))

  let assert Ok(reclaimed) =
    transport.acquire_connection_slot(sockets, "203.0.113.10")
  transport.release_connection_slot(reclaimed)

  release_gate(gate)
  let _fresh_frames = app_test_helper.connect(sockets, "fresh")
  let assert Ok(#(initialized_socket, _fresh_sender)) =
    process.receive(initialized, 1000)
  initialized_socket |> should.equal("fresh")
  process.receive(initialized, 100) |> should.be_error
  app_test_helper.recv_none(observer_frames)

  app_test_helper.join(sockets, "late", "room:a", "jr-late", "r-late")
  process.receive(late_frames, 100) |> should.be_error
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

// ── transport connection ownership status ───────────────────────────────────

pub fn runtime_pid_reports_alive_when_running_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  transport.runtime_pid(sockets)
  |> should.equal(Ok(app_test_helper.runtime_pid(sockets)))

  let assert Ok(_) = beryl.stop(sockets)
  Nil
}

pub fn runtime_pid_unavailable_before_start_test() -> Nil {
  let assert Ok(#(sockets, _spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  // The runtime is not running yet: a new connection cannot be owned, so the
  // transport must refuse it rather than admit a dead socket.
  transport.runtime_pid(sockets) |> should.be_error
}

// ── the embedded subtree dies with the application root ─────────────────────

pub fn application_root_shutdown_tears_down_beryl_subtree_test() -> Nil {
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()
  test_helper.wait_until(
    fn() { beryl.app_runtime_pid(sockets) |> result.is_ok },
    2000,
    10,
  )
  let runtime = app_test_helper.runtime_pid(sockets)
  let limiter = limiter_pid(sockets)

  // The application root goes down; the embedded beryl subtree, linked under
  // it, is torn down with it (unlink first so the test process survives).
  process.unlink(root.pid)
  process.kill(root.pid)

  test_helper.wait_until(fn() { !process.is_alive(runtime) }, 2000, 10)
  process.is_alive(runtime) |> should.be_false
  process.is_alive(limiter) |> should.be_false
  beryl.app_runtime_pid(sockets) |> should.be_error
}

// ── a partial startup failure leaks no beryl processes ──────────────────────

pub fn partial_startup_failure_tears_down_beryl_subtree_test() -> Nil {
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(5),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  // A sibling that always fails to start. The supervisor tears down the
  // already-started beryl subtree and exits, so the doomed startup is run in
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

  // Whether or not the doomed supervisor reported an error, no beryl runtime
  // or limiter is left running.
  test_helper.wait_until(
    fn() { beryl.app_runtime_pid(sockets) |> result.is_error },
    3000,
    20,
  )
  beryl.app_runtime_pid(sockets) |> should.be_error
  beryl.app_limiter_pid(sockets) |> should.be_error
}

// ── stop waits for the runtime even with no limiter ─────────────────────────

pub fn stop_without_limiter_waits_for_runtime_teardown_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  // No connection limit is configured, so there is no limiter in the subtree.
  beryl.app_limiter_pid(sockets) |> should.be_error
  let runtime = app_test_helper.runtime_pid(sockets)

  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // stop still waited for the runtime itself to terminate before returning.
  process.is_alive(runtime) |> should.be_false
}

// ── stop leaves no registered name or live process behind ───────────────────

pub fn stop_leaves_no_registered_name_or_process_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(3),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let runtime = app_test_helper.runtime_pid(sockets)
  let limiter = limiter_pid(sockets)

  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // Both processes are gone and their registered names no longer resolve.
  process.is_alive(runtime) |> should.be_false
  process.is_alive(limiter) |> should.be_false
  beryl.app_runtime_pid(sockets) |> should.be_error
  beryl.app_limiter_pid(sockets) |> should.be_error
  // The system is fully gone: a fresh connection cannot be admitted.
  transport.acquire_connection_slot(sockets, "1.2.3.4") |> should.be_error
}

// ── the socket factory owns the socket actors (ADR 0005) ────────────────────

fn socket_factory_pid(sockets: beryl.Sockets) -> process.Pid {
  let assert Ok(pid) = beryl.app_socket_factory_pid(sockets)
  pid
}

fn connected_sockets(sockets: beryl.Sockets) -> Int {
  case snapshot.get(sockets) {
    Ok(current_snapshot) -> snapshot.connected_sockets(current_snapshot)
    Error(_) -> -1
  }
}

pub fn socket_factory_crash_closes_sockets_and_recovers_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )

  let closed = process.new_subject()
  let runtime = app_test_helper.runtime_pid(sockets)
  admit(sockets, runtime, "factory-a", fn() {
    process.send(closed, "factory-a")
  })
  |> should.equal(Ok(Nil))
  admit(sockets, runtime, "factory-b", fn() {
    process.send(closed, "factory-b")
  })
  |> should.equal(Ok(Nil))

  // Both socket actors are owned children of the shared factory.
  let factory = socket_factory_pid(sockets)
  active_child_count(factory) |> should.equal(2)

  process.kill(factory)

  // The factory took its whole socket population with it, and the router
  // swept both actors through its monitors and closed their transports.
  let assert Ok(first) = process.receive(closed, 2000)
  let assert Ok(second) = process.receive(closed, 2000)
  [first, second]
  |> list.sort(string.compare)
  |> should.equal(["factory-a", "factory-b"])
  test_helper.wait_until(fn() { connected_sockets(sockets) == 0 }, 2000, 10)
  connected_sockets(sockets) |> should.equal(0)

  // Only the factory restarted: the permanent child comes back under the same
  // name while the router keeps running.
  test_helper.wait_until(
    fn() {
      case beryl.app_socket_factory_pid(sockets) {
        Ok(pid) -> pid != factory && process.is_alive(pid)
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )
  let recovered = socket_factory_pid(sockets)
  recovered |> should.not_equal(factory)
  beryl.app_runtime_pid(sockets) |> should.equal(Ok(runtime))
  active_child_count(recovered) |> should.equal(0)

  // New connections are accepted, and are children of the replacement.
  admit(sockets, runtime, "after-factory-crash", fn() { Nil })
  |> should.equal(Ok(Nil))
  active_child_count(recovered) |> should.equal(1)
  connected_sockets(sockets) |> should.equal(1)

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn cancelled_admission_leaves_no_booting_factory_child_test() -> Nil {
  let gate = new_gate()
  let init_entered = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: socket.ConnectInfo(Nil)) {
        process.send(init_entered, Nil)
        wait_for_gate(gate)
        #(Nil, [])
      },
      update: app_test_helper.accepting_update,
    )

  let factory = socket_factory_pid(sockets)
  let admission_result = process.new_subject()
  let connection_closed = process.new_subject()
  let _connection =
    process.spawn(fn() {
      let assert Ok(owner) = transport.runtime_pid(sockets)
      process.send(
        admission_result,
        transport.admit_socket(
          sockets: sockets,
          owner: owner,
          socket_id: "cancelled",
          send: fn(_message) { Ok(Nil) },
          send_binary: fn(_data) { Ok(Nil) },
          codec: None,
          seed: socket.empty_seed(),
          close: fn() { process.send(connection_closed, Nil) },
        ),
      )
    })

  // Phase one is done: the actor exists as a factory child while it is still
  // booting, before the application `init` has registered anything.
  process.receive(init_entered, 1000) |> should.equal(Ok(Nil))
  active_child_count(factory) |> should.equal(1)

  // The transport's admission wait expires and cancels the token.
  process.receive(admission_result, 2000) |> should.equal(Ok(Error(Nil)))
  process.receive(connection_closed, 1000) |> should.equal(Ok(Nil))

  // The booting actor finds its admission cancelled and stops instead of
  // leaking as a never-admitted child of the factory.
  release_gate(gate)
  test_helper.wait_until(fn() { active_child_count(factory) == 0 }, 2000, 10)
  active_child_count(factory) |> should.equal(0)
  test_helper.wait_until(fn() { connected_sockets(sockets) == 0 }, 2000, 10)
  connected_sockets(sockets) |> should.equal(0)

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn stop_drains_socket_actors_before_stopping_the_factory_test() -> Nil {
  let closes = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: fn(model, input) {
        case input {
          socket.Closed(topic, reason) -> {
            process.send(closes, #(topic, reason))
            Next(model, [])
          }
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          socket.Message(..) | socket.Binary(..) | socket.Info(..) ->
            Next(model, [])
        }
      },
    )

  let transport_closed = process.new_subject()
  let frames =
    app_test_helper.connect_with_close(sockets, "drained", fn() {
      process.send(transport_closed, Nil)
    })
  app_test_helper.join_ok(sockets, frames, "drained", "room:a", "jr-1", "r-1")
  let factory = socket_factory_pid(sockets)
  active_child_count(factory) |> should.equal(1)

  beryl.stop(sockets) |> should.equal(Ok(Nil))

  // The socket actor ran its shutdown teardown before the factory was
  // stopped: a factory shutdown that preceded the drain would have killed the
  // actor without ever delivering `Closed`.
  process.receive(closes, 1000)
  |> should.equal(Ok(#("room:a", socket.Shutdown)))
  process.receive(transport_closed, 1000) |> should.equal(Ok(Nil))

  // The factory is then torn down with the rest of the subtree.
  test_helper.wait_until(fn() { !process.is_alive(factory) }, 2000, 10)
  process.is_alive(factory) |> should.be_false
  beryl.app_socket_factory_pid(sockets) |> should.be_error
}

// ── transport close during `Booting` discards init effects (ADR 0005) ──────

pub fn cancelled_admission_during_booting_discards_init_effects_test() -> Nil {
  let gate = new_gate()
  let init_entered = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info: socket.ConnectInfo(Nil)) {
        case info.socket_id {
          "cancelled-with-effects" -> {
            process.send(init_entered, Nil)
            wait_for_gate(gate)
            #(Nil, [Broadcast("room:a", "leak", json.string("leaked"))])
          }
          _ -> #(Nil, [])
        }
      },
      update: app_test_helper.accepting_update,
    )

  // A bystander already joined to the topic the cancelled init would
  // broadcast to: if the cancelled `init`'s effects ever leaked into the
  // runtime, this socket would see the broadcast frame.
  let frames = app_test_helper.connect(sockets, "bystander")
  app_test_helper.join_ok(sockets, frames, "bystander", "room:a", "jr-0", "r-0")

  let factory = socket_factory_pid(sockets)
  active_child_count(factory) |> should.equal(1)

  let admission_result = process.new_subject()
  let connection_closed = process.new_subject()
  let _connection =
    process.spawn(fn() {
      let assert Ok(owner) = transport.runtime_pid(sockets)
      process.send(
        admission_result,
        transport.admit_socket(
          sockets: sockets,
          owner: owner,
          socket_id: "cancelled-with-effects",
          send: fn(_message) { Ok(Nil) },
          send_binary: fn(_data) { Ok(Nil) },
          codec: None,
          seed: socket.empty_seed(),
          close: fn() { process.send(connection_closed, Nil) },
        ),
      )
    })

  // Phase one is done: the actor exists as a factory child while `init` is
  // still running, before it has registered anything.
  process.receive(init_entered, 1000) |> should.equal(Ok(Nil))
  active_child_count(factory) |> should.equal(2)

  // The transport's admission wait expires and closes the connection while
  // `init` is still running -- a transport close/disconnect during
  // `Booting`.
  process.receive(admission_result, 2000) |> should.equal(Ok(Error(Nil)))
  process.receive(connection_closed, 1000) |> should.equal(Ok(Nil))

  release_gate(gate)

  // The cancelled actor stops instead of leaking as a factory child, and its
  // `init` effects -- queued behind the cancellation check -- never apply:
  // the bystander never sees the broadcast.
  test_helper.wait_until(fn() { active_child_count(factory) == 1 }, 2000, 10)
  active_child_count(factory) |> should.equal(1)
  app_test_helper.recv_none(frames)

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

// ── graceful stop drains a `Booting` socket alongside an `Active` one ──────
// (ADR 0005)

pub fn stop_drains_active_and_booting_socket_actors_test() -> Nil {
  let gate = new_gate()
  let init_entered = process.new_subject()
  let closes = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info: socket.ConnectInfo(Nil)) {
        case info.socket_id {
          "booting" -> {
            process.send(init_entered, Nil)
            wait_for_gate(gate)
            Nil
          }
          _ -> Nil
        }
        #(Nil, [])
      },
      update: fn(model, input) {
        case input {
          socket.Closed(topic, reason) -> {
            process.send(closes, #(topic, reason))
            Next(model, [])
          }
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          socket.Message(..) | socket.Binary(..) | socket.Info(..) ->
            Next(model, [])
        }
      },
    )

  let transport_closed = process.new_subject()
  let frames =
    app_test_helper.connect_with_close(sockets, "active", fn() {
      process.send(transport_closed, Nil)
    })
  app_test_helper.join_ok(sockets, frames, "active", "room:a", "jr-1", "r-1")

  let factory = socket_factory_pid(sockets)
  active_child_count(factory) |> should.equal(1)

  // A second connection whose `init` is gated: it stays `Booting`.
  let admission_result = process.new_subject()
  let booting_closed = process.new_subject()
  let _connection =
    process.spawn(fn() {
      let assert Ok(owner) = transport.runtime_pid(sockets)
      process.send(
        admission_result,
        transport.admit_socket(
          sockets: sockets,
          owner: owner,
          socket_id: "booting",
          send: fn(_message) { Ok(Nil) },
          send_binary: fn(_data) { Ok(Nil) },
          codec: None,
          seed: socket.empty_seed(),
          close: fn() { process.send(booting_closed, Nil) },
        ),
      )
    })
  process.receive(init_entered, 1000) |> should.equal(Ok(Nil))
  active_child_count(factory) |> should.equal(2)

  // `stop` blocks until the whole subtree drains, so it runs in its own
  // process.
  let stop_result = process.new_subject()
  process.spawn(fn() { process.send(stop_result, beryl.stop(sockets)) })

  // The drain waits for every socket actor to finish shutdown phase one
  // before it tears any of them down: the already-`Active` socket's
  // `Closed` and transport close have not fired while its sibling is still
  // `Booting`.
  process.receive(closes, 150) |> should.be_error
  process.receive(transport_closed, 150) |> should.be_error

  release_gate(gate)

  // The booting socket finishes `init`, registers, and immediately reports
  // its own shutdown phase one; only then does the drain proceed for both
  // sockets.
  process.receive(admission_result, 2000) |> should.equal(Ok(Ok(Nil)))
  process.receive(booting_closed, 1000) |> should.equal(Ok(Nil))
  process.receive(closes, 1000)
  |> should.equal(Ok(#("room:a", socket.Shutdown)))
  process.receive(transport_closed, 1000) |> should.equal(Ok(Nil))

  // `stop` completes with its documented result once the drain finishes.
  process.receive(stop_result, 2000) |> should.equal(Ok(Ok(Nil)))

  // No booting factory child is left behind; the whole subtree is gone.
  test_helper.wait_until(fn() { !process.is_alive(factory) }, 2000, 10)
  process.is_alive(factory) |> should.be_false
  beryl.app_socket_factory_pid(sockets) |> should.be_error
}
