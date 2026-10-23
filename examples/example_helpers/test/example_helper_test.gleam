import example_helper/session_presence
import gleam/erlang/process
import gleam/json
import gleam/list
import gleeunit
import gleeunit/should

@external(erlang, "example_session_presence_test_ffi", "mailbox_length")
fn mailbox_length(pid: process.Pid) -> Int

@external(erlang, "example_session_presence_test_ffi", "with_suspended")
fn with_suspended(pid: process.Pid, action: fn() -> a) -> a

@external(erlang, "example_session_presence_test_ffi", "monitor_count")
fn monitor_count(pid: process.Pid) -> Int

@external(erlang, "example_session_presence_test_ffi", "collected_memory")
fn collected_memory(pid: process.Pid) -> Int

pub fn main() -> Nil {
  gleeunit.main()
}

fn wait_until(check: fn() -> Bool, timeout_ms: Int) -> Nil {
  case check() {
    True -> Nil
    False -> {
      case timeout_ms <= 0 {
        True -> should.be_true(False)
        False -> {
          process.sleep(10)
          wait_until(check, timeout_ms - 10)
        }
      }
    }
  }
}

fn await_down(monitor: process.Monitor) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  Nil
}

pub fn abandoned_queued_admission_does_not_consume_capacity_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let topic = "room:queued"

  with_suspended(session_presence.process_id(tracker), fn() {
    let caller =
      process.spawn_unlinked(fn() {
        let _ =
          session_presence.track_if_below(
            tracker,
            topic,
            "abandoned",
            json.object([]),
            1,
          )
        Nil
      })
    let monitor = process.monitor(caller)
    wait_until(
      fn() { mailbox_length(session_presence.process_id(tracker)) > 0 },
      1000,
    )
    process.kill(caller)
    await_down(monitor)
  })

  session_presence.track_if_below(tracker, topic, "live", json.object([]), 1)
  |> should.equal(Ok(Nil))
  session_presence.count(tracker, topic) |> should.equal(1)
  session_presence.stop(tracker)
  |> should.equal(Ok(Nil))
}

pub fn at_capacity_returns_descriptive_error_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let topic = "room:full"

  session_presence.track_if_below(tracker, topic, "first", json.object([]), 1)
  |> should.equal(Ok(Nil))
  session_presence.track_if_below(tracker, topic, "second", json.object([]), 1)
  |> should.equal(Error(session_presence.AtCapacity))

  session_presence.stop(tracker)
  |> should.equal(Ok(Nil))
}

pub fn owner_death_reclaims_admitted_capacity_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let topic = "room:owner"
  let admitted = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let result =
        session_presence.track_if_below(
          tracker,
          topic,
          "departed",
          json.object([]),
          1,
        )
      process.send(admitted, result)
      process.receive_forever(process.new_subject())
    })
  let monitor = process.monitor(owner)

  process.receive(admitted, 1000) |> should.equal(Ok(Ok(Nil)))
  session_presence.count(tracker, topic) |> should.equal(1)
  process.kill(owner)
  await_down(monitor)
  wait_until(fn() { session_presence.count(tracker, topic) == 0 }, 1000)

  session_presence.track_if_below(
    tracker,
    topic,
    "replacement",
    json.object([]),
    1,
  )
  |> should.equal(Ok(Nil))
  session_presence.stop(tracker)
  |> should.equal(Ok(Nil))
}

pub fn owner_death_removes_unbounded_sessions_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let topic = "room:unbounded"
  let tracked = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      session_presence.track(tracker, topic, "published", json.object([]))
      session_presence.track_without_publish(
        tracker,
        topic,
        "deferred",
        json.object([]),
      )
      process.send(tracked, Nil)
      process.receive_forever(process.new_subject())
    })
  let monitor = process.monitor(owner)

  process.receive(tracked, 1000) |> should.equal(Ok(Nil))
  session_presence.count(tracker, topic) |> should.equal(2)
  process.kill(owner)
  await_down(monitor)
  wait_until(fn() { session_presence.count(tracker, topic) == 0 }, 1000)

  session_presence.stop(tracker) |> should.equal(Ok(Nil))
}

pub fn abandoned_queued_unbounded_track_is_removed_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let topic = "room:queued-unbounded"

  with_suspended(session_presence.process_id(tracker), fn() {
    let owner =
      process.spawn_unlinked(fn() {
        session_presence.track_without_publish(
          tracker,
          topic,
          "abandoned",
          json.object([]),
        )
      })
    let monitor = process.monitor(owner)
    wait_until(
      fn() { mailbox_length(session_presence.process_id(tracker)) > 0 },
      1000,
    )
    process.kill(owner)
    await_down(monitor)
  })

  session_presence.untrack(tracker, topic, "barrier")
  wait_until(fn() { session_presence.count(tracker, topic) == 0 }, 1000)
  session_presence.stop(tracker) |> should.equal(Ok(Nil))
}

pub fn retracking_and_untracking_release_live_owner_monitors_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let pid = session_presence.process_id(tracker)
  let baseline = monitor_count(pid)
  let topic = "room:live-owner"

  list.each(list.repeat(Nil, 100), fn(_) {
    session_presence.track_without_publish(
      tracker,
      topic,
      "session",
      json.object([]),
    )
  })
  monitor_count(pid) |> should.equal(baseline + 1)

  session_presence.untrack(tracker, topic, "session")
  monitor_count(pid) |> should.equal(baseline)
  session_presence.count(tracker, topic) |> should.equal(0)

  list.each(list.repeat(Nil, 100), fn(_) {
    session_presence.track_if_below(
      tracker,
      topic,
      "session",
      json.object([]),
      1,
    )
    |> should.equal(Ok(Nil))
    session_presence.untrack(tracker, topic, "session")
  })
  monitor_count(pid) |> should.equal(baseline)
  session_presence.stop(tracker) |> should.equal(Ok(Nil))
}

pub fn previous_owner_exit_does_not_remove_replacement_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let topic = "room:replacement"
  let tracked = process.new_subject()
  let previous_owner =
    process.spawn_unlinked(fn() {
      session_presence.track_without_publish(
        tracker,
        topic,
        "session",
        json.object([]),
      )
      process.send(tracked, Nil)
      process.receive_forever(process.new_subject())
    })
  let monitor = process.monitor(previous_owner)
  process.receive(tracked, 1000) |> should.equal(Ok(Nil))

  session_presence.track_without_publish(
    tracker,
    topic,
    "session",
    json.object([]),
  )
  monitor_count(session_presence.process_id(tracker)) |> should.equal(2)
  process.kill(previous_owner)
  await_down(monitor)
  session_presence.untrack(tracker, topic, "barrier")
  session_presence.count(tracker, topic) |> should.equal(1)

  session_presence.untrack(tracker, topic, "session")
  session_presence.stop(tracker) |> should.equal(Ok(Nil))
}

pub fn departed_owner_churn_does_not_retain_selector_handlers_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let pid = session_presence.process_id(tracker)
  churn_departed_owners(tracker, 20)
  let baseline_monitors = monitor_count(pid)
  let baseline_memory = collected_memory(pid)

  churn_departed_owners(tracker, 1000)
  monitor_count(pid) |> should.equal(baseline_monitors)
  // Allow heap sizing variation, but not a handler per departed owner.
  { collected_memory(pid) < baseline_memory + 65_536 } |> should.be_true
  session_presence.stop(tracker) |> should.equal(Ok(Nil))
}

fn churn_departed_owners(tracker: session_presence.Tracker, count: Int) -> Nil {
  let topic = "room:churn"
  let tracked = process.new_subject()
  list.each(list.repeat(Nil, count), fn(_) {
    let owner =
      process.spawn_unlinked(fn() {
        let result =
          session_presence.track_if_below(
            tracker,
            topic,
            "session",
            json.object([]),
            1,
          )
        process.send(tracked, result)
        process.receive_forever(process.new_subject())
      })
    let monitor = process.monitor(owner)
    process.receive(tracked, 1000) |> should.equal(Ok(Ok(Nil)))
    process.kill(owner)
    await_down(monitor)
    wait_until(fn() { session_presence.count(tracker, topic) == 0 }, 1000)
  })
  session_presence.untrack(tracker, topic, "barrier")
}

pub fn stop_releases_the_populated_store_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  session_presence.track(tracker, "room:stop", "session", json.object([]))

  session_presence.store_is_alive(tracker) |> should.be_true
  session_presence.count(tracker, "room:stop") |> should.equal(1)
  session_presence.stop(tracker)
  |> should.equal(Ok(Nil))
  session_presence.store_is_alive(tracker) |> should.be_false
}

pub fn tracker_failure_releases_the_store_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  session_presence.track(
    tracker,
    "room:tracker-failure",
    "session",
    json.object([]),
  )
  let monitor = process.monitor(session_presence.process_id(tracker))

  process.kill(session_presence.process_id(tracker))
  await_down(monitor)

  session_presence.store_is_alive(tracker) |> should.be_false
}

pub fn starter_failure_releases_the_store_test() -> Nil {
  let started = process.new_subject()
  let starter =
    process.spawn_unlinked(fn() {
      let assert Ok(tracker) = session_presence.start()
      process.send(started, tracker)
      process.receive_forever(process.new_subject())
    })
  let assert Ok(tracker) = process.receive(started, 1000)
  let starter_monitor = process.monitor(starter)
  let tracker_monitor = process.monitor(session_presence.process_id(tracker))

  session_presence.store_is_alive(tracker) |> should.be_true
  process.kill(starter)
  await_down(starter_monitor)
  await_down(tracker_monitor)

  session_presence.store_is_alive(tracker) |> should.be_false
}

pub fn startup_timeout_terminates_worker_and_releases_store_test() -> Nil {
  let prepared = process.new_subject()
  let result =
    session_presence.start_with_initialiser(1000, fn(tracker) {
      process.send(prepared, tracker)
      process.receive_forever(process.new_subject())
    })

  result |> should.equal(Error(session_presence.StartTimedOut))
  let assert Ok(tracker) = process.receive(prepared, 1000)
  session_presence.is_running(tracker) |> should.be_false
  session_presence.store_is_alive(tracker) |> should.be_false
}

pub fn startup_worker_exit_returns_error_to_live_caller_test() -> Nil {
  let prepared = process.new_subject()
  let result =
    session_presence.start_with_initialiser(1000, fn(tracker) {
      process.send(prepared, tracker)
      process.kill(process.self())
    })

  let assert Error(session_presence.StartExited(_reason)) = result
  let assert Ok(tracker) = process.receive(prepared, 1000)
  session_presence.is_running(tracker) |> should.be_false
  session_presence.store_is_alive(tracker) |> should.be_false
}

pub fn shutdown_timeout_returns_error_and_preserves_queued_stop_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let monitor = process.monitor(session_presence.process_id(tracker))

  with_suspended(session_presence.process_id(tracker), fn() {
    session_presence.stop_with_timeout(tracker, 10)
    |> should.equal(Error(session_presence.StopTimedOut))
    session_presence.is_running(tracker) |> should.be_true
    session_presence.store_is_alive(tracker) |> should.be_true
  })
  await_down(monitor)

  session_presence.store_is_alive(tracker) |> should.be_false
}

pub fn shutdown_unavailable_worker_returns_error_to_live_caller_test() -> Nil {
  let assert Ok(tracker) = session_presence.start()
  let monitor = process.monitor(session_presence.process_id(tracker))
  process.kill(session_presence.process_id(tracker))
  await_down(monitor)

  let assert Error(session_presence.StopExited(_reason)) =
    session_presence.stop(tracker)
  session_presence.store_is_alive(tracker) |> should.be_false
}
