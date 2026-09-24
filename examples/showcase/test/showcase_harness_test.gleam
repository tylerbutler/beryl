import gleeunit/should
import showcase_harness
import unitest

@external(erlang, "showcase_harness_test_ffi", "without_error_logs")
fn without_error_logs(action: fn() -> Nil) -> Bool

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
