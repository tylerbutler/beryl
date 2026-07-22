//// Shared test helpers for beryl tests
////
//// Provides polling utilities to replace fragile `process.sleep()` calls
//// with deterministic condition-based waiting.

import beryl/coordinator
import gleam/erlang/process
import gleeunit/should

/// A stateless joined-channel instance whose callbacks all no-op and return
/// the same instance, for coordinator-level tests that don't exercise
/// channel state.
pub fn noop_instance() -> coordinator.JoinedChannel {
  coordinator.JoinedChannel(
    handle_in: fn(_event, _payload, _ctx) {
      coordinator.NoReplyErased(next: noop_instance())
    },
    handle_binary: fn(_data, _ctx) {
      coordinator.NoReplyErased(next: noop_instance())
    },
    handle_info: fn(_message, _ctx) {
      coordinator.NoReplyErased(next: noop_instance())
    },
    terminate: fn(_reason, _ctx) { Nil },
  )
}

/// Poll a condition function until it returns True, or fail after timeout.
///
/// Replaces fragile `process.sleep(N)` calls in tests with a deterministic
/// polling loop. The check function is called repeatedly at the given interval
/// until it returns True or the timeout is exhausted.
///
/// ## Example
///
/// ```gleam
/// // Wait until presence list has 2 entries (up to 2 seconds)
/// wait_until(fn() { list.length(presence.list(p1, "room:lobby")) == 2 }, 2000, 20)
/// ```
pub fn wait_until(
  check: fn() -> Bool,
  timeout_ms: Int,
  interval_ms: Int,
) -> Nil {
  case check() {
    True -> Nil
    False -> {
      case timeout_ms <= 0 {
        True -> should.be_true(False)
        False -> {
          process.sleep(interval_ms)
          wait_until(check, timeout_ms - interval_ms, interval_ms)
        }
      }
    }
  }
}
