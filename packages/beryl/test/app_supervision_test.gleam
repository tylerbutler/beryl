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
import beryl/socket.{AcceptJoin, Broadcast, Join, Next}
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleeunit/should
import test_helpers

type Gate

@external(erlang, "beryl_supervisor_test_ffi", "gate_new")
fn new_gate() -> Gate

@external(erlang, "beryl_supervisor_test_ffi", "gate_wait")
fn wait_for_gate(gate: Gate) -> Nil

@external(erlang, "beryl_supervisor_test_ffi", "gate_release")
fn release_gate(gate: Gate) -> Nil

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
    fn() { beryl.app_runtime_pid(sockets) |> result.is_ok },
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
    h.start_app(
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
    h.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_connection_rate_per_ip(per_second: 1, burst: 1),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  let limiter = limiter_pid(sockets)
  let old_runtime = h.runtime_pid(sockets)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.10")
  transport.release_connection_slot(permit)

  // Crash the runtime abnormally; the transient significant child restarts.
  process.kill(old_runtime)

  // The exhausted IP bucket remains live while dispatch restarts.
  transport.acquire_connection_slot(sockets, "192.0.2.10")
  |> should.be_error

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

  // A runtime restart does not restart the limiter: same pid and rate state.
  limiter_pid(sockets) |> should.equal(limiter)
  process.is_alive(limiter) |> should.be_true

  // Stopping the subtree still tears the (surviving) limiter down.
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  process.is_alive(limiter) |> should.be_false
}

pub fn limiter_restart_preserves_connection_state_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(1)
        |> beryl.with_connection_rate_per_ip(per_second: 1, burst: 2),
      init: h.accepting_init,
      update: h.accepting_update,
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
  test_helpers.wait_until(
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

pub fn runtime_crash_during_stop_recovers_and_second_stop_succeeds_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  let recovered_runtime = crash_runtime_during_stop(sockets)
  process.is_alive(recovered_runtime) |> should.be_true

  beryl.stop(sockets) |> should.equal(Ok(Nil))
  process.is_alive(recovered_runtime) |> should.be_false
  beryl.app_runtime_pid(sockets) |> should.be_error
}

pub fn unresponsive_socket_stop_returns_timeout_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )
  let gate = new_gate()
  let stop_entered = process.new_subject()
  let stop_result = process.new_subject()

  admit(sockets, h.runtime_pid(sockets), "stuck-stop", fn() {
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

pub fn runtime_crash_during_stop_does_not_hide_later_exhaustion_test() {
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
    fn() { beryl.app_runtime_pid(sockets) |> result.is_ok },
    2000,
    10,
  )
  let original_limiter = limiter_pid(sockets)
  let runtime2 = crash_runtime_during_stop(sockets)

  // The crash during stop counts as the first failure in the nested
  // supervisor's restart window. Three more rapid crashes must therefore
  // exhaust it and restart the whole Beryl subtree under the application root.
  process.kill(runtime2)
  let runtime3 = wait_for_new_runtime(sockets, runtime2)
  process.kill(runtime3)
  let runtime4 = wait_for_new_runtime(sockets, runtime3)
  process.kill(runtime4)

  test_helpers.wait_until(
    fn() {
      case beryl.app_limiter_pid(sockets), beryl.app_runtime_pid(sockets) {
        Ok(limiter), Ok(runtime) ->
          limiter != original_limiter && runtime != runtime4
        _, _ -> False
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
  let old_runtime = h.runtime_pid(sockets)

  admit(sockets, h.runtime_pid(sockets), "crash-during-stop", fn() {
    process.send(stop_entered, Nil)
    wait_for_gate(gate)
  })
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

pub fn restart_intensity_exhaustion_restarts_outer_subtree_test() {
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
    fn() { beryl.app_runtime_pid(sockets) |> result.is_ok },
    2000,
    10,
  )

  let original_limiter = limiter_pid(sockets)
  let runtime1 = h.runtime_pid(sockets)
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
  test_helpers.wait_until(
    fn() {
      case beryl.app_limiter_pid(sockets), beryl.app_runtime_pid(sockets) {
        Ok(limiter), Ok(runtime) ->
          limiter != original_limiter && runtime != runtime4
        _, _ -> False
      }
    },
    3000,
    10,
  )

  let recovered_runtime = h.runtime_pid(sockets)
  limiter_pid(sockets) |> should.not_equal(original_limiter)

  // The original name-backed Sockets handle is re-registered and usable.
  admit(sockets, h.runtime_pid(sockets), "after-exhaustion", fn() { Nil })
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
  h.runtime_pid(sockets)
}

// ── a runtime crash closes connections that monitor the accepting runtime ──

pub fn runtime_crash_closes_owned_connection_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  let closed = process.new_subject()
  let ready = process.new_subject()

  // Simulate a transport connection process: it monitors the runtime that
  // accepted it before registration and closes when that exact runtime dies.
  let _conn =
    process.spawn(fn() {
      case transport.runtime_pid(sockets) {
        Ok(pid) -> {
          let mon = process.monitor(pid)
          let selector =
            process.new_selector()
            |> process.select_specific_monitor(mon, fn(_down) { Nil })
          process.send(ready, Nil)
          let _ = process.selector_receive(selector, 2000)
          process.send(closed, Nil)
        }
        _ -> Nil
      }
    })

  // Wait for the monitor-installation handshake rather than sleeping.
  process.receive(ready, 1000) |> should.equal(Ok(Nil))
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

fn crashing_update(model: Nil, ev: socket.Input(Nil)) -> socket.Next(Nil) {
  case ev {
    Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
    socket.Info(_) -> panic as "boom"
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
  let owner = h.runtime_pid(sockets)
  admit(sockets, owner, "s1", fn() { process.send(closed, Nil) })
  |> should.equal(Ok(Nil))
  let assert Ok(sender) = process.receive(senders, 1000)

  // Drive an app-info event into the crashing update; the runtime rescues the
  // crash, tears the socket down, and runs its registered close callback.
  socket.notify(sender, Nil)

  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  // The runtime itself survives the rescued crash and keeps serving.
  process.is_alive(h.runtime_pid(sockets)) |> should.be_true
}

pub fn failed_registration_closes_connection_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: socket.ConnectInfo(Nil)) { panic as "init failed" },
      update: h.accepting_update,
    )
  let closed = process.new_subject()

  admit(sockets, h.runtime_pid(sockets), "failed-init", fn() {
    process.send(closed, Nil)
  })
  |> should.be_error

  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  process.is_alive(h.runtime_pid(sockets)) |> should.be_true
}

pub fn stale_runtime_owner_cannot_register_with_successor_test() {
  let initialized = process.new_subject()
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info: socket.ConnectInfo(Nil)) {
        process.send(initialized, info.socket_id)
        #(Nil, [])
      },
      update: h.accepting_update,
    )
  let assert Ok(old_runtime) = transport.runtime_pid(sockets)
  let monitor = process.monitor(old_runtime)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })

  process.kill(old_runtime)
  process.selector_receive(selector, 2000) |> should.equal(Ok(Nil))
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

  let closed = process.new_subject()
  admit(sockets, old_runtime, "stale-owner", fn() { process.send(closed, Nil) })
  |> should.be_error
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  process.receive(initialized, 100) |> should.be_error
  process.is_alive(h.runtime_pid(sockets)) |> should.be_true
}

pub fn timed_out_admission_cannot_register_or_apply_init_effects_test() {
  let initialized = process.new_subject()
  let init_entered = process.new_subject()
  let gate = new_gate()
  let assert Ok(sockets) =
    h.start_app(
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
          _ -> Next(model, [])
        }
      },
    )

  let observer_frames = h.connect(sockets, "observer")
  let assert Ok(#("observer", _observer)) = process.receive(initialized, 1000)
  h.join(sockets, "observer", "room:a", "jr-observer", "r-observer")
  let _join_reply = h.recv(observer_frames)

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
  let _fresh_frames = h.connect(sockets, "fresh")
  let assert Ok(#(initialized_socket, _fresh_sender)) =
    process.receive(initialized, 1000)
  initialized_socket |> should.equal("fresh")
  process.receive(initialized, 100) |> should.be_error
  h.recv_none(observer_frames)

  h.join(sockets, "late", "room:a", "jr-late", "r-late")
  process.receive(late_frames, 100) |> should.be_error
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

// ── transport connection ownership status ───────────────────────────────────

pub fn runtime_pid_reports_alive_when_running_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  transport.runtime_pid(sockets) |> should.equal(Ok(h.runtime_pid(sockets)))

  let assert Ok(_) = beryl.stop(sockets)
}

pub fn runtime_pid_unavailable_before_start_test() {
  let assert Ok(#(sockets, _spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  // The runtime is not running yet: a new connection cannot be owned, so the
  // transport must refuse it rather than admit a dead socket.
  transport.runtime_pid(sockets) |> should.be_error
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
    fn() { beryl.app_runtime_pid(sockets) |> result.is_ok },
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
  test_helpers.wait_until(
    fn() { beryl.app_runtime_pid(sockets) |> result.is_error },
    3000,
    20,
  )
  beryl.app_runtime_pid(sockets) |> should.be_error
  beryl.app_limiter_pid(sockets) |> should.be_error
}

// ── stop waits for the runtime even with no limiter ─────────────────────────

pub fn stop_without_limiter_waits_for_runtime_teardown_test() {
  let assert Ok(sockets) =
    h.start_app(
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
    h.start_app(
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
  transport.acquire_connection_slot(sockets, "1.2.3.4") |> should.be_error
}
