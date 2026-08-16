import gleeunit/should
import showcase_harness as h

pub fn stop_terminates_the_presence_publisher_test() {
  let system = h.start("presence-lifecycle")
  h.presence_is_running(system) |> should.be_true

  h.stop(system)
  h.presence_is_running(system) |> should.be_false
  h.presence_is_running(system) |> should.be_false
}
