import example_helper/session_presence
import gleam/erlang/process
import gleam/json
import gleeunit
import gleeunit/should

@external(erlang, "example_session_presence_test_ffi", "mailbox_length")
fn mailbox_length(pid: process.Pid) -> Int

@external(erlang, "example_session_presence_test_ffi", "with_suspended")
fn with_suspended(pid: process.Pid, action: fn() -> a) -> a

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
  let tracker = session_presence.start()
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
}

pub fn at_capacity_returns_descriptive_error_test() -> Nil {
  let tracker = session_presence.start()
  let topic = "room:full"

  session_presence.track_if_below(tracker, topic, "first", json.object([]), 1)
  |> should.equal(Ok(Nil))
  session_presence.track_if_below(tracker, topic, "second", json.object([]), 1)
  |> should.equal(Error(session_presence.AtCapacity))

  session_presence.stop(tracker)
}

pub fn owner_death_reclaims_admitted_capacity_test() -> Nil {
  let tracker = session_presence.start()
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
}
