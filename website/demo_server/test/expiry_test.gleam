import beryl_demo/expiry
import gleam/erlang/atom
import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
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
  |> should.equal(Ok(Nil))

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
  |> should.equal(Ok(Nil))
  expiry.track(manager, "demo:presence:test", "socket-2", fn() {
    process.send(expired, "socket-2")
  })
  |> should.equal(Ok(Nil))
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
  |> should.equal(Ok(Nil))
  expiry.stop(manager)

  // Wait well past the configured TTL. The timer scheduled inside the actor
  // fires against a dead process, so the callback must never run.
  process.sleep(400)
  process.receive(expired, 50) |> should.equal(Error(Nil))
}

pub fn registration_after_expiry_is_rejected_test() {
  let expired = process.new_subject()
  let assert Ok(manager) = expiry.start(100)
  expiry.track(manager, "demo:presence:late", "first", fn() {
    process.send(expired, "first")
  })
  |> should.equal(Ok(Nil))
  process.receive(expired, 500) |> should.equal(Ok("first"))
  expiry.track(manager, "demo:presence:late", "late", fn() {
    process.send(expired, "late")
  })
  |> should.equal(Error(Nil))
  process.receive(expired, 150) |> should.equal(Error(Nil))
  expiry.stop(manager)
}

pub fn timers_do_not_cross_supervised_incarnations_test() {
  let children = process.new_subject()
  let expired = process.new_subject()
  let #(manager, specification) = expiry.child_spec(500)
  let observed =
    supervision.ChildSpecification(..specification, start: fn() {
      let assert Ok(started) = specification.start()
      process.send(children, started.pid)
      Ok(started)
    })
  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(observed)
    |> static_supervisor.start
  let assert Ok(first) = process.receive(children, 1000)
  expiry.track(manager, "topic", "first", fn() {
    process.send(expired, "first")
  })
  |> should.equal(Ok(Nil))
  process.sleep(150)
  process.send_abnormal_exit(first, atom.create("kill"))
  let assert Ok(_replacement) = process.receive(children, 1000)
  expiry.track(manager, "topic", "replacement", fn() {
    process.send(expired, "replacement")
  })
  |> should.equal(Ok(Nil))

  process.receive(expired, 400) |> should.equal(Error(Nil))
  process.receive(expired, 300) |> should.equal(Ok("replacement"))
  process.receive(expired, 400) |> should.equal(Error(Nil))
  expiry.is_expired(manager, "topic") |> should.be_true

  let monitor = process.monitor(root.pid)
  process.unlink(root.pid)
  process.send_abnormal_exit(root.pid, atom.create("shutdown"))
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
}
