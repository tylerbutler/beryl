import beryl_site/presence/reconnect
import gleam/option.{None, Some}
import gleeunit/should

pub fn reconnect_schedule_is_bounded_test() {
  reconnect.delay(1) |> should.equal(Some(1000))
  reconnect.delay(2) |> should.equal(Some(2000))
  reconnect.delay(3) |> should.equal(Some(5000))
  reconnect.delay(4) |> should.equal(Some(10_000))
  reconnect.delay(5) |> should.equal(Some(10_000))
  reconnect.delay(6) |> should.equal(None)
}
