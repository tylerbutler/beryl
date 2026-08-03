//// Shared test helpers for beryl tests
////
//// Provides polling utilities to replace fragile `process.sleep()` calls
//// with deterministic condition-based waiting, plus a palabres log-capture
//// harness (backed by the `beryl_log_capture` Erlang test handler) used to
//// observe runtime-side logging as a proxy for "did the decoded envelope
//// reach the runtime", where reply presence/absence alone cannot
//// distinguish edge-level shedding from runtime-level shedding.

import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
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

// ── Palabres log capture ────────────────────────────────────────────────────

/// A single captured palabres log: its message and string-keyed metadata.
pub type CapturedLog {
  CapturedLog(message: String, metadata: dict.Dict(String, String))
}

@external(erlang, "beryl_log_capture", "start")
fn start_capture(pid: process.Pid) -> Nil

@external(erlang, "beryl_log_capture", "stop")
fn stop_capture_ffi() -> Nil

fn captured_decoder() -> decode.Decoder(CapturedLog) {
  use message <- decode.field(1, decode.string)
  use metadata <- decode.field(2, decode.dict(decode.string, decode.string))
  decode.success(CapturedLog(message:, metadata:))
}

fn coerce_captured(value: dynamic.Dynamic) -> CapturedLog {
  case decode.run(value, captured_decoder()) {
    Ok(captured) -> captured
    Error(_) -> CapturedLog(message: "", metadata: dict.new())
  }
}

fn captured_selector() -> process.Selector(CapturedLog) {
  process.new_selector()
  |> process.select_record(atom.create("captured_log"), 2, coerce_captured)
}

fn drain(selector: process.Selector(CapturedLog)) -> Nil {
  case process.selector_receive(selector, 0) {
    Ok(_) -> drain(selector)
    Error(Nil) -> Nil
  }
}

/// Install the capture handler (bound to the calling process) and return a
/// drained selector ready to observe logs emitted from this point on. Pair
/// with `stop_capture` once the test is done.
pub fn begin_capture() -> process.Selector(CapturedLog) {
  start_capture(process.self())
  let selector = captured_selector()
  drain(selector)
  selector
}

/// Remove the capture handler installed by `begin_capture`.
pub fn stop_capture() -> Nil {
  stop_capture_ffi()
}

/// Receive captured logs from `selector` until one matching `message`
/// arrives (`Ok`), a mismatching log has been seen `attempts` times without
/// a match, or no further log arrives within 500ms (`Error(Nil)` in either
/// case). A small `attempts` count combined with the 500ms per-attempt wait
/// also makes this usable as an absence check.
pub fn receive_log(
  selector: process.Selector(CapturedLog),
  message: String,
  attempts: Int,
) -> Result(CapturedLog, Nil) {
  case attempts <= 0 {
    True -> Error(Nil)
    False ->
      case process.selector_receive(selector, 500) {
        Ok(captured) ->
          case captured.message == message {
            True -> Ok(captured)
            False -> receive_log(selector, message, attempts - 1)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}
