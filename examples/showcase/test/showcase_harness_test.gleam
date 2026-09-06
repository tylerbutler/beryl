import gleeunit/should
import showcase_harness

pub fn stop_terminates_the_presence_publisher_test() -> Nil {
  let system = showcase_harness.start("presence-lifecycle")
  showcase_harness.presence_is_running(system) |> should.be_true

  showcase_harness.stop(system)
  showcase_harness.presence_is_running(system) |> should.be_false
  showcase_harness.presence_is_running(system) |> should.be_false
}
