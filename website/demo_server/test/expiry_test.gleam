import beryl_demo/expiry
import gleam/erlang/process
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn expires_a_tracked_topic_test() {
  let expired = process.new_subject()
  let assert Ok(manager) = expiry.start(100)
  expiry.initialize(manager, fn(socket_id, topic) {
    process.send(expired, #(socket_id, topic))
  })
  expiry.track(manager, "demo:presence:test", "socket-1")

  process.receive(expired, 500)
  |> should.equal(Ok(#("socket-1", "demo:presence:test")))
  expiry.is_expired(manager, "demo:presence:test")
  |> should.be_true
  expiry.stop(manager)
}
