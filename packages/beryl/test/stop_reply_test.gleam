//// Regression tests for the private, caller-owned stop reply scope.

import beryl/app_supervisor
import beryl/internal
import beryl/overload
import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import test_helper
import unitest

@external(erlang, "beryl_ffi", "with_reply_subject")
fn with_reply_subject(action: fn(process.Subject(message)) -> value) -> value

type Reply {
  Completed
}

// Leave an unrelated tagged message queued throughout each scope. Cleanup must
// neither consume it nor change the caller's monitor or mailbox baseline.
fn with_mailbox_baseline(action: fn() -> Nil) -> Nil {
  let caller = process.self()
  let monitors = test_helper.monitor_count(caller)
  let messages = test_helper.mailbox_length(caller)
  let unrelated = process.new_subject()
  process.send(unrelated, "unrelated")

  action()

  test_helper.monitor_count(caller) |> should.equal(monitors)
  test_helper.mailbox_length(caller) |> should.equal(messages + 1)
  process.new_selector()
  |> process.select(unrelated)
  |> process.selector_receive(0)
  |> should.equal(Ok("unrelated"))
  test_helper.mailbox_length(caller) |> should.equal(messages)
}

/// A selector can consume an alias-owned reply while the scope is active.
pub fn scoped_reply_can_be_consumed_test() -> Nil {
  use <- with_mailbox_baseline
  let outcome =
    with_reply_subject(fn(reply) {
      process.send(reply, Completed)
      // process.receive checks for a pid owner and rejects this alias subject.
      process.new_selector()
      |> process.select(reply)
      |> process.selector_receive(0)
    })
  outcome |> should.equal(Ok(Completed))
}

/// An unconsumed completion already in the mailbox is flushed on scope exit.
pub fn queued_reply_is_flushed_on_scope_exit_test() -> Nil {
  use <- with_mailbox_baseline
  let messages = test_helper.mailbox_length(process.self())
  let reply =
    with_reply_subject(fn(reply) {
      process.send(reply, Completed)
      test_helper.mailbox_length(process.self()) |> should.equal(messages + 1)
      reply
    })
  process.new_selector()
  |> process.select(reply)
  |> process.selector_receive(0)
  |> should.equal(Error(Nil))
}

/// Retaining a subject does not keep its reply alias active after scope exit.
pub fn sends_after_scope_exit_are_dropped_test() -> Nil {
  use <- with_mailbox_baseline
  let reply = with_reply_subject(fn(reply) { reply })
  process.send(reply, Completed)
  process.new_selector()
  |> process.select(reply)
  |> process.selector_receive(0)
  |> should.equal(Error(Nil))
}

/// Exceptions propagate through rescue only after flushing and deactivation.
pub fn callback_exception_deactivates_and_flushes_test() -> Nil {
  use <- with_mailbox_baseline
  let escaped = process.new_subject()
  let messages = test_helper.mailbox_length(process.self())
  let assert Error(description) =
    internal.rescue(fn() {
      with_reply_subject(fn(reply) {
        process.send(escaped, reply)
        process.send(reply, Completed)
        test_helper.mailbox_length(process.self()) |> should.equal(messages + 2)
        panic as "stop reply callback failed"
      })
    })
  string.contains(description, "stop reply callback failed")
  |> should.be_true()

  let assert Ok(reply) =
    process.new_selector()
    |> process.select(escaped)
    |> process.selector_receive(0)
  let selector = process.new_selector() |> process.select(reply)
  process.selector_receive(selector, 0) |> should.equal(Error(Nil))
  process.send(reply, Completed)
  process.selector_receive(selector, 0) |> should.equal(Error(Nil))
}

/// An exception before any reply must also deactivate the still-active alias.
pub fn callback_exception_before_reply_deactivates_test() -> Nil {
  use <- with_mailbox_baseline
  let escaped = process.new_subject()
  let assert Error(description) =
    internal.rescue(fn() {
      with_reply_subject(fn(reply) {
        process.send(escaped, reply)
        panic as "no reply"
      })
    })
  string.contains(description, "no reply")
  |> should.be_true()

  let assert Ok(reply) =
    process.new_selector()
    |> process.select(escaped)
    |> process.selector_receive(0)
  process.send(reply, Completed)
  process.new_selector()
  |> process.select(reply)
  |> process.selector_receive(0)
  |> should.equal(Error(Nil))
}

/// A taken stop request can still finish after its acceptance caller times out.
pub fn acceptance_timeout_drops_both_late_stop_replies_test() -> Nil {
  use <- unitest.tag("serial")
  use <- with_isolated_caller
  use <- with_mailbox_baseline
  let caller = process.self()
  let entered = process.new_subject()
  let nested = process.new_subject()
  let name = process.new_name("late_stop_acceptance")
  let assert Ok(started) =
    app_supervisor.start(
      name,
      fn(finished) {
        let proceed = process.new_subject()
        process.send(entered, #(proceed, finished))
        let assert Ok(Nil) = process.receive(proceed, 3000)
        Ok(process.monitor(caller))
      },
      fn() {
        let assert Ok(supervisor) =
          static_supervisor.new(static_supervisor.OneForOne)
          |> static_supervisor.start()
        process.send(nested, supervisor.pid)
        Ok(supervisor)
      },
    )
  let assert Ok(supervisor) = process.receive(nested, 0)
  let outcome =
    with_reply_subject(fn(finished) {
      app_supervisor.request_stop(name, finished)
    })
  outcome |> should.equal(Error(overload.RequestTimedOut))
  let assert Ok(#(proceed, runtime_stopped)) = process.receive(entered, 0)
  process.send(proceed, Nil)

  let monitor = process.monitor(started.pid)
  process.send(runtime_stopped, app_supervisor.StopCompleted)
  process.kill(supervisor)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  Nil
}

// Prior heartbeat fixtures can send messages during the acceptance timeout.
// A fresh caller keeps the exact mailbox baseline specific to stop replies.
fn with_isolated_caller(action: fn() -> Nil) -> Nil {
  let completed = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      action()
      process.send(completed, Nil)
      // Stay alive until the runner has installed its monitor and cleans up.
      process.sleep_forever()
    })
  let monitor = process.monitor(caller)
  let selector =
    process.new_selector()
    |> process.select_map(completed, fn(_) { Ok(Nil) })
    |> process.select_specific_monitor(monitor, Error)
  let outcome = process.selector_receive(selector, 5000)

  // Caller exit also tears down its linked app supervisor on a timeout.
  process.kill(caller)
  let stopped = case outcome {
    Ok(Error(down)) -> Ok(down)
    Ok(Ok(Nil)) | Error(Nil) ->
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(1000)
  }
  process.demonitor_process(monitor)
  // After the caller is down, consume at most its private completion race.
  case process.receive(completed, 0) {
    Ok(Nil) | Error(Nil) -> Nil
  }
  stopped |> should.be_ok
  // A failed child assertion is Error(down), not a successful completion.
  outcome |> should.equal(Ok(Ok(Nil)))
}
