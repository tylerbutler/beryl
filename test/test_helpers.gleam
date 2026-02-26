//// Shared test helpers for beryl tests
////
//// Provides polling utilities to replace fragile `process.sleep()` calls
//// with deterministic condition-based waiting.

import gleam/erlang/process
import gleeunit/should

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
pub fn wait_until(check: fn() -> Bool, timeout_ms: Int, interval_ms: Int) -> Nil {
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
