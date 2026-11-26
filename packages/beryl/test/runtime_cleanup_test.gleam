//// Focused router-index regressions. Existing ownership, permit reuse,
//// factory-crash and ordered-disconnect tests remain the broader coverage.

import app_test_helper
import beryl
import beryl/runtime
import beryl/snapshot
import beryl/transport
import beryl/wire/codec
import beryl/work_queue
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/otp/system
import gleam/string
import gleeunit/should
import runtime_cleanup_workload as workload
import test_helper
import unitest

@external(erlang, "beryl_router_ownership_test_ffi", "with_cleanup")
fn with_cleanup(action: fn() -> value, cleanup: fn() -> Nil) -> value

@external(erlang, "beryl_runtime_cleanup_test_ffi", "with_full_router")
fn with_full_router(
  queue: work_queue.Queue(runtime.Message(Nil)),
  action: fn() -> value,
) -> value

@external(erlang, "beryl_test_process_ffi", "socket_queue")
fn socket_queue(
  router: process.Pid,
  id: String,
) -> work_queue.Queue(runtime.Message(Nil))

@external(erlang, "beryl_runtime_cleanup_test_ffi", "down_pending")
fn down_pending(router: process.Pid, actor: process.Pid) -> Bool

@external(erlang, "beryl_runtime_cleanup_test_ffi", "assert_monitor_index")
fn assert_monitor_index(
  router: process.Pid,
  actors: List(#(String, process.Pid)),
) -> Nil

@external(erlang, "beryl_test_process_ffi", "socket_actor")
fn socket_actor(router: process.Pid, id: String) -> process.Pid

@external(erlang, "beryl_supervisor_test_ffi", "active_child_count")
fn active_child_count(factory: process.Pid) -> Int

@external(erlang, "beryl_runtime_telemetry_test_ffi", "inject_router_message")
fn inject(router: process.Pid, message: runtime.Message(Nil)) -> Nil

type Capture

@external(erlang, "beryl_runtime_telemetry_test_ffi", "with_capture")
fn with_capture(action: fn(Capture) -> value) -> value

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_connected")
fn expect_connected(capture: Capture) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_join")
fn expect_join(capture: Capture, outcome: String) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_disconnect")
fn expect_disconnect(capture: Capture, reason: String, joined: Int) -> Bool

@external(erlang, "beryl_runtime_telemetry_test_ffi", "expect_none")
fn expect_none(capture: Capture) -> Bool

fn peer_delivery(
  fixture: workload.Fixture,
  peer: workload.Connection,
  topic: String,
) -> Nil {
  beryl.broadcast(fixture.sockets, topic, "cleanup-probe", json.null())
  |> should.equal(Ok(Nil))
  let assert Ok(frame) = process.receive(peer.frames, 1000)
  frame |> string.contains("\"cleanup-probe\"") |> should.be_true
}

fn normal_close(
  fixture: workload.Fixture,
  connection: workload.Connection,
) -> Nil {
  transport.socket_disconnected(fixture.sockets, connection.id)
  workload.await_removed(fixture, [connection])
  workload.stop_owner(connection)
}

fn await_monitor_baseline(fixture: workload.Fixture, baseline: Int) -> Nil {
  test_helper.wait_until(
    fn() { test_helper.monitor_count(fixture.router) == baseline },
    2000,
    1,
  )
  test_helper.monitor_count(fixture.router) |> should.equal(baseline)
  assert_monitor_index(fixture.router, [])
}

fn assert_current_monitors(
  fixture: workload.Fixture,
  connections: List(workload.Connection),
) -> Nil {
  assert_monitor_index(
    fixture.router,
    list.map(connections, fn(connection) { #(connection.id, connection.actor) }),
  )
}

/// Own shared/exclusive memberships disappear; unrelated and healthy sockets
/// retain exact counts and real delivery after normal close or actor Down.
pub fn shared_exclusive_unrelated_cleanup_test() -> Nil {
  list.each([False, True], fn(kill_actor) {
    test_helper.with_isolated_caller(15_000, fn() {
      workload.with_fixture(False, app_test_helper.accepting_init, fn(fixture) {
        let baseline = test_helper.monitor_count(fixture.router)
        let departing = workload.connect(fixture, "departing")
        let peer = workload.connect(fixture, "healthy")
        let unrelated = workload.connect(fixture, "unrelated")
        workload.join(fixture, departing, "room:shared")
        workload.join(fixture, departing, "room:exclusive")
        workload.join(fixture, peer, "room:shared")
        workload.join(fixture, peer, "room:healthy")
        workload.join(fixture, unrelated, "room:unrelated")
        workload.await_counts(fixture, #(3, 5, 4))
        assert_current_monitors(fixture, [departing, peer, unrelated])
        case kill_actor {
          True -> process.kill(departing.actor)
          False -> transport.socket_disconnected(fixture.sockets, departing.id)
        }
        workload.await_removed(fixture, [departing])
        workload.await_counts(fixture, #(2, 3, 3))
        assert_current_monitors(fixture, [peer, unrelated])
        workload.stop_owner(departing)
        process.receive(fixture.closed, 1000) |> should.equal(Ok("departing"))
        inject(
          fixture.router,
          runtime.SocketClosed("departing", departing.actor),
        )
        inject(
          fixture.router,
          runtime.IndexLeave("departing", departing.actor, "room:shared"),
        )
        workload.counts(fixture) |> should.equal(#(2, 3, 3))
        process.receive(fixture.closed, 0) |> should.equal(Error(Nil))
        peer_delivery(fixture, peer, "room:shared")
        peer_delivery(fixture, unrelated, "room:unrelated")
        normal_close(fixture, peer)
        normal_close(fixture, unrelated)
        workload.await_counts(fixture, #(0, 0, 0))
        await_monitor_baseline(fixture, baseline)
        beryl.stop(fixture.sockets) |> should.equal(Ok(Nil))
      })
    })
  })
}

/// Real publication rejection, not a fabricated reverse-index inconsistency:
/// fill router admission, then execute phx_leave on the real socket actor.
pub fn rejected_index_leave_is_swept_at_terminal_cleanup_test() -> Nil {
  use <- unitest.tag("serial")
  test_helper.with_isolated_caller(15_000, fn() {
    workload.with_fixture(False, app_test_helper.accepting_init, fn(fixture) {
      let baseline = test_helper.monitor_count(fixture.router)
      let departing = workload.connect(fixture, "departing")
      let peer = workload.connect(fixture, "healthy")
      workload.join(fixture, departing, "room:shared")
      workload.join(fixture, departing, "room:exclusive")
      workload.join(fixture, peer, "room:shared")
      workload.await_counts(fixture, #(2, 3, 2))
      assert_current_monitors(fixture, [departing, peer])
      let target = socket_queue(fixture.router, departing.id)
      let assert Ok(before) = snapshot.queue(fixture.sockets)
      let assert Ok(leave) =
        codec.decode_text(transport.active_codec(fixture.sockets))(
          "[\"room:shared\",\"leave\",\"room:shared\",\"phx_leave\",{}]",
        )
      with_full_router(fixture.queue, fn() {
        // This only bypasses router ingress to isolate IndexLeave pressure;
        // decode, protocol transition, publication and teardown are real.
        work_queue.send(target, runtime.RouteDecoded(departing.id, leave))
        |> should.equal(Ok(Nil))
        test_helper.wait_until(
          fn() { !process.is_alive(departing.actor) },
          2000,
          1,
        )
        let assert Ok(after) = snapshot.queue(fixture.sockets)
        should.be_true(after.rejected > before.rejected)
      })
      workload.await_removed(fixture, [departing])
      workload.await_counts(fixture, #(1, 1, 1))
      assert_current_monitors(fixture, [peer])
      workload.stop_owner(departing)
      peer_delivery(fixture, peer, "room:shared")
      normal_close(fixture, peer)
      workload.await_counts(fixture, #(0, 0, 0))
      await_monitor_baseline(fixture, baseline)
      beryl.stop(fixture.sockets) |> should.equal(Ok(Nil))
    })
  })
}

/// A delayed queued join can cross a real actor Down in either scheduling
/// order. Terminal removal or the existing ID/PID guard must erase/ignore it.
pub fn queued_index_join_crossing_down_test() -> Nil {
  use <- unitest.tag("serial")
  test_helper.with_isolated_caller(15_000, fn() {
    workload.with_fixture(False, app_test_helper.accepting_init, fn(fixture) {
      let departing = workload.connect(fixture, "departing")
      workload.join(fixture, departing, "room:exclusive")
      workload.await_counts(fixture, #(1, 1, 1))
      assert_current_monitors(fixture, [departing])
      system.suspend(fixture.router)
      with_cleanup(
        fn() {
          // Queue a REAL IndexJoin while the router cannot consume it. The
          // actor publishes this before its join reply, then dies before the
          // router can process either membership notification or Down.
          let assert Ok(join) =
            codec.decode_text(transport.active_codec(fixture.sockets))(
              "[\"late\",\"late\",\"room:late\",\"phx_join\",{}]",
            )
          work_queue.send(
            socket_queue(fixture.router, departing.id),
            runtime.RouteDecoded(departing.id, join),
          )
          |> should.equal(Ok(Nil))
          let assert Ok(reply) = process.receive(departing.frames, 1000)
          reply |> string.contains("\"status\":\"ok\"") |> should.be_true
          process.kill(departing.actor)
          test_helper.wait_until(
            fn() { down_pending(fixture.router, departing.actor) },
            1000,
            1,
          )
          // Also model a delayed old publication queued after the real Down.
          // Queue wake/recovery may consume it on either side of removal.
          work_queue.send(
            fixture.queue,
            runtime.IndexJoin(departing.id, departing.actor, "room:late"),
          )
          |> should.equal(Ok(Nil))
        },
        fn() { system.resume(fixture.router) },
      )
      workload.await_removed(fixture, [departing])
      workload.await_counts(fixture, #(0, 0, 0))
      assert_current_monitors(fixture, [])
      workload.stop_owner(departing)
      let fresh = workload.connect(fixture, "departing")
      workload.join(fixture, fresh, "room:shared")
      inject(
        fixture.router,
        runtime.IndexJoin("departing", departing.actor, "room:late"),
      )
      inject(
        fixture.router,
        runtime.IndexLeave("departing", departing.actor, "room:shared"),
      )
      inject(fixture.router, runtime.SocketClosed("departing", departing.actor))
      // Duplicate current joins are set-idempotent as well.
      inject(
        fixture.router,
        runtime.IndexJoin("departing", fresh.actor, "room:shared"),
      )
      inject(
        fixture.router,
        runtime.IndexJoin("departing", fresh.actor, "room:shared"),
      )
      workload.counts(fixture) |> should.equal(#(1, 1, 1))
      assert_current_monitors(fixture, [fresh])
      peer_delivery(fixture, fresh, "room:shared")
      normal_close(fixture, fresh)
      workload.await_counts(fixture, #(0, 0, 0))
      assert_current_monitors(fixture, [])
      beryl.stop(fixture.sockets) |> should.equal(Ok(Nil))
    })
  })
}

/// An owner Down for a claimed admission closes normally; an owner that
/// abandons a still-blocked init cancels it. Both monitor entries are removed.
pub fn both_monitor_kinds_restore_baseline_test() -> Nil {
  use <- unitest.tag("serial")
  test_helper.with_isolated_caller(15_000, fn() {
    let entered = process.new_subject()
    workload.with_fixture(
      False,
      fn(info) {
        case info.socket_id {
          "abandoned" -> {
            process.send(entered, Nil)
            process.sleep_forever()
          }
          _ -> Nil
        }
        #(Nil, [])
      },
      fn(fixture) {
        let baseline = test_helper.monitor_count(fixture.router)
        assert_current_monitors(fixture, [])
        let claimed = workload.connect(fixture, "claimed")
        workload.join(fixture, claimed, "room:shared")
        workload.join(fixture, claimed, "room:exclusive")
        workload.await_counts(fixture, #(1, 2, 2))
        assert_current_monitors(fixture, [claimed])
        workload.stop_owner(claimed)
        workload.await_removed(fixture, [claimed])
        workload.await_counts(fixture, #(0, 0, 0))
        await_monitor_baseline(fixture, baseline)
        let caller =
          process.spawn(fn() {
            let _frames = app_test_helper.connect(fixture.sockets, "abandoned")
          })
        let monitor = process.monitor(caller)
        process.receive(entered, 2000) |> should.equal(Ok(Nil))
        workload.await_counts(fixture, #(1, 0, 0))
        assert_monitor_index(fixture.router, [
          #("abandoned", socket_actor(fixture.router, "abandoned")),
        ])
        // It is intentionally killed while in the synchronous admit call.
        process.unlink(caller)
        process.kill(caller)
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive(2000)
        |> should.be_ok
        process.demonitor_process(monitor)
        workload.await_counts(fixture, #(0, 0, 0))
        await_monitor_baseline(fixture, baseline)
        beryl.stop(fixture.sockets) |> should.equal(Ok(Nil))
      },
    )
  })
}

/// Factory death kills real joined children. Router monitor dictionaries and
/// topics return to empty before recovered factory admits the same socket IDs.
pub fn joined_factory_crash_restores_monitor_index_and_reuses_ids_test() -> Nil {
  use <- unitest.tag("serial")
  test_helper.with_isolated_caller(15_000, fn() {
    workload.with_fixture(False, app_test_helper.accepting_init, fn(fixture) {
      let baseline = test_helper.monitor_count(fixture.router)
      assert_current_monitors(fixture, [])
      let first = workload.connect(fixture, "factory-a")
      let second = workload.connect(fixture, "factory-b")
      workload.join(fixture, first, "room:shared")
      workload.join(fixture, first, "room:exclusive-a")
      workload.join(fixture, second, "room:shared")
      workload.join(fixture, second, "room:exclusive-b")
      workload.await_counts(fixture, #(2, 4, 3))
      assert_current_monitors(fixture, [first, second])
      let assert Ok(factory) = beryl.app_socket_factory_pid(fixture.sockets)
      active_child_count(factory) |> should.equal(2)
      process.kill(factory)
      workload.await_removed(fixture, [first, second])
      workload.await_counts(fixture, #(0, 0, 0))
      await_monitor_baseline(fixture, baseline)
      workload.stop_owner(first)
      workload.stop_owner(second)
      let assert Ok(first_closed) = process.receive(fixture.closed, 2000)
      let assert Ok(second_closed) = process.receive(fixture.closed, 2000)
      [first_closed, second_closed]
      |> list.sort(string.compare)
      |> should.equal(["factory-a", "factory-b"])
      process.receive(fixture.closed, 0) |> should.equal(Error(Nil))
      test_helper.wait_until(
        fn() {
          case beryl.app_socket_factory_pid(fixture.sockets) {
            Ok(pid) -> pid != factory && process.is_alive(pid)
            Error(Nil) -> False
          }
        },
        2000,
        1,
      )
      let assert Ok(recovered) = beryl.app_socket_factory_pid(fixture.sockets)
      active_child_count(recovered) |> should.equal(0)
      beryl.app_runtime_pid(fixture.sockets) |> should.equal(Ok(fixture.router))
      let fresh_first = workload.connect(fixture, "factory-a")
      let fresh_second = workload.connect(fixture, "factory-b")
      workload.join(fixture, fresh_first, "room:shared")
      workload.join(fixture, fresh_second, "room:shared")
      workload.await_counts(fixture, #(2, 2, 1))
      assert_current_monitors(fixture, [fresh_first, fresh_second])
      active_child_count(recovered) |> should.equal(2)
      list.each([first, second], fn(old) {
        inject(fixture.router, runtime.SocketClosed(old.id, old.actor))
        inject(
          fixture.router,
          runtime.IndexJoin(old.id, old.actor, "room:ghost"),
        )
        inject(
          fixture.router,
          runtime.IndexLeave(old.id, old.actor, "room:shared"),
        )
      })
      workload.counts(fixture) |> should.equal(#(2, 2, 1))
      assert_current_monitors(fixture, [fresh_first, fresh_second])
      peer_delivery(fixture, fresh_first, "room:shared")
      let assert Ok(peer_frame) = process.receive(fresh_second.frames, 1000)
      peer_frame |> string.contains("\"cleanup-probe\"") |> should.be_true
      normal_close(fixture, fresh_first)
      normal_close(fixture, fresh_second)
      workload.await_counts(fixture, #(0, 0, 0))
      await_monitor_baseline(fixture, baseline)
      beryl.stop(fixture.sockets) |> should.equal(Ok(Nil))
    })
  })
}

/// The dead actor cannot report telemetry: the router counts its OWN two
/// topics exactly once, and duplicate/late terminal notifications do not emit.
pub fn abnormal_telemetry_counts_own_memberships_once_test() -> Nil {
  use <- unitest.tag("serial")
  test_helper.with_isolated_caller(15_000, fn() {
    with_capture(fn(capture) {
      workload.with_fixture(True, app_test_helper.accepting_init, fn(fixture) {
        let departing = workload.connect(fixture, "departing")
        expect_connected(capture) |> should.be_true
        workload.join(fixture, departing, "room:shared")
        expect_join(capture, "accepted") |> should.be_true
        workload.join(fixture, departing, "room:exclusive")
        expect_join(capture, "accepted") |> should.be_true
        workload.await_counts(fixture, #(1, 2, 2))
        process.kill(departing.actor)
        workload.await_removed(fixture, [departing])
        workload.await_counts(fixture, #(0, 0, 0))
        expect_disconnect(capture, "socket_process_down", 2) |> should.be_true
        inject(
          fixture.router,
          runtime.SocketClosed("departing", departing.actor),
        )
        inject(
          fixture.router,
          runtime.IndexJoin("departing", departing.actor, "room:late"),
        )
        workload.counts(fixture) |> should.equal(#(0, 0, 0))
        expect_none(capture) |> should.be_true
        workload.stop_owner(departing)
        beryl.stop(fixture.sockets) |> should.equal(Ok(Nil))
      })
    })
  })
}
