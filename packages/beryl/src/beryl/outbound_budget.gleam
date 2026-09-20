//// Atomic frame and byte reservations for one connection's outbound writes.

import gleam/bool
import gleam/erlang/process
import gleam/int
import rasa/atomic

const bytes_per_frame = 1_099_511_627_776

const closed_state = -1

pub opaque type Budget {
  Budget(state: atomic.Atomic)
}

/// Create an open budget with no reservations.
pub fn new() -> Budget {
  Budget(atomic.new())
}

/// Reserve capacity and send a message when both limits permit it.
pub fn reserve_and_send(
  budget: Budget,
  subject: process.Subject(message),
  message: message,
  bytes: Int,
  max_frames: Int,
  max_bytes: Int,
) -> Bool {
  reserve_and_send_from(
    budget,
    subject,
    message,
    bytes,
    max_frames,
    max_bytes,
    atomic.get(budget.state),
  )
}

fn reserve_and_send_from(
  budget: Budget,
  subject: process.Subject(message),
  message: message,
  bytes: Int,
  max_frames: Int,
  max_bytes: Int,
  state: Int,
) -> Bool {
  use <- bool.guard(when: state < 0, return: False)
  let frames = state / bytes_per_frame
  let reserved_bytes = state % bytes_per_frame
  use <- bool.lazy_guard(
    when: frames + 1 > max_frames || reserved_bytes + bytes > max_bytes,
    return: fn() { close_and_reject(budget, state) },
  )

  let next_state = state + bytes_per_frame + bytes
  case atomic.compare_exchange(budget.state, state, next_state) {
    Ok(Nil) -> {
      process.send(subject, message)
      True
    }
    Error(actual) ->
      reserve_and_send_from(
        budget,
        subject,
        message,
        bytes,
        max_frames,
        max_bytes,
        actual,
      )
  }
}

fn close_and_reject(budget: Budget, state: Int) -> Bool {
  close_from(budget, state)
  False
}

/// Release one frame and its payload-byte reservation while open.
pub fn release(budget: Budget, bytes: Int) -> Nil {
  release_from(budget, bytes, atomic.get(budget.state))
}

fn release_from(budget: Budget, bytes: Int, state: Int) -> Nil {
  use <- bool.guard(when: state < 0, return: Nil)
  let next_state = int.max(state - bytes_per_frame - bytes, 0)
  case atomic.compare_exchange(budget.state, state, next_state) {
    Ok(Nil) -> Nil
    Error(actual) -> release_from(budget, bytes, actual)
  }
}

/// Close the budget and send one close message.
pub fn close_and_send(
  budget: Budget,
  subject: process.Subject(message),
  message: message,
) -> Nil {
  close_and_send_from(budget, subject, message, atomic.get(budget.state))
}

fn close_and_send_from(
  budget: Budget,
  subject: process.Subject(message),
  message: message,
  state: Int,
) -> Nil {
  use <- bool.guard(when: state < 0, return: Nil)
  case atomic.compare_exchange(budget.state, state, closed_state) {
    Ok(Nil) -> process.send(subject, message)
    Error(actual) -> close_and_send_from(budget, subject, message, actual)
  }
}

/// Close the budget without sending a message.
pub fn cancel(budget: Budget) -> Nil {
  close_from(budget, atomic.get(budget.state))
}

fn close_from(budget: Budget, state: Int) -> Nil {
  use <- bool.guard(when: state < 0, return: Nil)
  case atomic.compare_exchange(budget.state, state, closed_state) {
    Ok(Nil) -> Nil
    Error(actual) -> close_from(budget, actual)
  }
}
