import beryl/snapshot
import beryl/transport
import example_helper/session_presence
import gleam/erlang/process
import gleam/result
import gleam/string
import gleeunit/should
import showcase_harness
import unitest

@external(erlang, "showcase_harness_test_ffi", "without_error_logs")
fn without_error_logs(action: fn() -> Nil) -> Bool

@external(erlang, "showcase_harness_test_ffi", "socket_actor")
fn socket_actor(router: process.Pid, socket_id: String) -> process.Pid

pub fn socket_crash_removes_cursor_presence_and_publishes_roster_test() -> Nil {
  use <- unitest.tag("serial")
  let system = showcase_harness.start("cursor-crash")
  let observer = showcase_harness.connect(system, "observer")
  showcase_harness.join(
    system,
    "observer",
    "cursor:main",
    "1",
    "{\"username\":\"observer\"}",
  )
  let _reply = showcase_harness.expect(observer, ["phx_reply", "\"ok\""])
  let _roster = showcase_harness.expect(observer, ["presence_list", "observer"])

  let departed = showcase_harness.connect(system, "departed")
  showcase_harness.join(
    system,
    "departed",
    "cursor:main",
    "1",
    "{\"username\":\"ada\"}",
  )
  let _reply = showcase_harness.expect(departed, ["phx_reply", "\"ok\""])
  let _roster = showcase_harness.expect(departed, ["presence_list", "departed"])
  let _observer_roster =
    showcase_harness.expect(observer, ["presence_list", "departed"])
  session_presence.count(system.presence, "cursor:main") |> should.equal(2)

  let assert Ok(router) = transport.runtime_pid(system.sockets)
  let actor = socket_actor(router, "departed")
  let monitor = process.monitor(actor)
  process.kill(actor)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))

  wait_until(
    fn() {
      snapshot.get(system.sockets)
      |> result.map(snapshot.connected_sockets)
      == Ok(1)
      && session_presence.count(system.presence, "cursor:main") == 1
    },
    1000,
  )
  let roster = showcase_harness.expect(observer, ["presence_list", "observer"])
  string.contains(roster, "departed") |> should.be_false
  showcase_harness.stop(system)
}

fn wait_until(check: fn() -> Bool, timeout_ms: Int) -> Nil {
  case check() {
    True -> Nil
    False ->
      case timeout_ms <= 0 {
        True -> should.be_true(False)
        False -> {
          process.sleep(10)
          wait_until(check, timeout_ms - 10)
        }
      }
  }
}

pub fn stop_closes_joined_channels_before_presence_publisher_test() -> Nil {
  use <- unitest.tag("serial")
  let system = showcase_harness.start("presence-lifecycle")
  let frames = showcase_harness.connect(system, "s1")
  showcase_harness.join(
    system,
    "s1",
    "cursor:main",
    "1",
    "{\"username\":\"ada\"}",
  )
  let _join_reply = showcase_harness.recv(frames)
  let _roster = showcase_harness.recv(frames)
  showcase_harness.presence_is_running(system) |> should.be_true

  without_error_logs(fn() { showcase_harness.stop(system) })
  |> should.be_true
  showcase_harness.presence_is_running(system) |> should.be_false
  showcase_harness.presence_is_running(system) |> should.be_false
}
