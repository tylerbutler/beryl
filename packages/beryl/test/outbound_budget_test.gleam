import beryl/outbound_budget
import gleam/erlang/process
import gleam/list
import gleeunit/should

pub fn reservations_enforce_frame_and_byte_limits_test() -> Nil {
  let frame_budget = outbound_budget.new()
  let frame_messages = process.new_subject()

  outbound_budget.reserve_and_send(frame_budget, frame_messages, "one", 1, 2, 8)
  |> should.be_true
  outbound_budget.reserve_and_send(frame_budget, frame_messages, "two", 1, 2, 8)
  |> should.be_true
  outbound_budget.reserve_and_send(
    frame_budget,
    frame_messages,
    "three",
    1,
    2,
    8,
  )
  |> should.be_false
  outbound_budget.reserve_and_send(
    frame_budget,
    frame_messages,
    "four",
    1,
    2,
    8,
  )
  |> should.be_false

  process.receive(frame_messages, 100) |> should.equal(Ok("one"))
  process.receive(frame_messages, 100) |> should.equal(Ok("two"))
  process.receive(frame_messages, 10) |> should.equal(Error(Nil))

  let byte_budget = outbound_budget.new()
  let byte_messages = process.new_subject()
  outbound_budget.reserve_and_send(byte_budget, byte_messages, "five", 8, 2, 8)
  |> should.be_true
  outbound_budget.reserve_and_send(byte_budget, byte_messages, "six", 1, 2, 8)
  |> should.be_false

  process.receive(byte_messages, 100) |> should.equal(Ok("five"))
  process.receive(byte_messages, 10) |> should.equal(Error(Nil))
}

pub fn release_makes_capacity_available_test() -> Nil {
  let budget = outbound_budget.new()
  let messages = process.new_subject()

  outbound_budget.reserve_and_send(budget, messages, "one", 8, 1, 8)
  |> should.be_true
  outbound_budget.release(budget, 8)
  outbound_budget.reserve_and_send(budget, messages, "two", 8, 1, 8)
  |> should.be_true

  process.receive(messages, 100) |> should.equal(Ok("one"))
  process.receive(messages, 100) |> should.equal(Ok("two"))
}

pub fn concurrent_reservations_do_not_exceed_limits_test() -> Nil {
  let budget = outbound_budget.new()
  let messages = process.new_subject()
  let results = process.new_subject()

  list.repeat(Nil, 20)
  |> list.each(fn(_) {
    process.spawn(fn() {
      let reserved =
        outbound_budget.reserve_and_send(budget, messages, Nil, 1, 3, 3)
      process.send(results, reserved)
    })
  })

  receive_results(results, 20, [])
  |> list.filter(fn(result) { result })
  |> list.length
  |> should.equal(3)
  receive_messages(messages, 3, []) |> list.length |> should.equal(3)
  process.receive(messages, 10) |> should.equal(Error(Nil))
}

pub fn close_sends_once_and_stops_reservations_test() -> Nil {
  let budget = outbound_budget.new()
  let messages = process.new_subject()
  let completed = process.new_subject()

  list.repeat(Nil, 20)
  |> list.each(fn(_) {
    process.spawn(fn() {
      outbound_budget.close_and_send(budget, messages, "close")
      process.send(completed, Nil)
    })
  })

  receive_messages(completed, 20, []) |> list.length |> should.equal(20)
  process.receive(messages, 100) |> should.equal(Ok("close"))
  process.receive(messages, 10) |> should.equal(Error(Nil))
  outbound_budget.reserve_and_send(budget, messages, "data", 1, 1, 1)
  |> should.be_false
}

pub fn cancellation_stops_reservations_without_sending_test() -> Nil {
  let budget = outbound_budget.new()
  let messages = process.new_subject()

  outbound_budget.cancel(budget)

  outbound_budget.reserve_and_send(budget, messages, "data", 1, 1, 1)
  |> should.be_false
  process.receive(messages, 10) |> should.equal(Error(Nil))
}

fn receive_results(
  subject: process.Subject(Bool),
  remaining: Int,
  results: List(Bool),
) -> List(Bool) {
  case remaining {
    0 -> results
    remaining -> {
      let assert Ok(result) = process.receive(subject, 1000)
      receive_results(subject, remaining - 1, [result, ..results])
    }
  }
}

fn receive_messages(
  subject: process.Subject(Nil),
  remaining: Int,
  messages: List(Nil),
) -> List(Nil) {
  case remaining {
    0 -> messages
    remaining -> {
      let assert Ok(message) = process.receive(subject, 1000)
      receive_messages(subject, remaining - 1, [message, ..messages])
    }
  }
}
