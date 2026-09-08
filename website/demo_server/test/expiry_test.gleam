import beryl_demo/expiry
import gleam/erlang/process
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn expires_a_tracked_topic_test() {
  let expired = process.new_subject()
  let assert Ok(manager) = expiry.start(100)
  expiry.track(manager, "demo:presence:test", "socket-1", fn() {
    process.send(expired, "socket-1")
  })

  process.receive(expired, 500) |> should.equal(Ok("socket-1"))
  expiry.is_expired(manager, "demo:presence:test") |> should.be_true
  expiry.stop(manager)
}

pub fn untracked_socket_does_not_run_its_callback_test() {
  let expired = process.new_subject()
  let assert Ok(manager) = expiry.start(100)
  expiry.track(manager, "demo:presence:test", "socket-1", fn() {
    process.send(expired, "socket-1")
  })
  expiry.track(manager, "demo:presence:test", "socket-2", fn() {
    process.send(expired, "socket-2")
  })
  expiry.untrack(manager, "demo:presence:test", "socket-1")

  process.receive(expired, 500) |> should.equal(Ok("socket-2"))
  process.receive(expired, 50) |> should.equal(Error(Nil))
  expiry.stop(manager)
}

/// Regression: synchronous `stop` must fully drain the actor before it returns,
/// so a scheduled expiry timer already in flight cannot run the callback
/// after teardown reports success. The TTL is chosen long enough that the
/// `ExpireTopic` timer message has not yet been enqueued when `stop` is called,
/// which lets the Stop message be processed first and terminate the actor
/// before the timer fires.
pub fn synchronous_stop_prevents_scheduled_callback_test() {
  let expired = process.new_subject()
  let assert Ok(manager) = expiry.start(100)
  expiry.track(manager, "demo:presence:sync", "socket-1", fn() {
    process.send(expired, "socket-1")
  })
  expiry.stop(manager)

  // Wait well past the configured TTL. The timer scheduled inside the actor
  // fires against a dead process, so the callback must never run.
  process.sleep(400)
  process.receive(expired, 50) |> should.equal(Error(Nil))
}
