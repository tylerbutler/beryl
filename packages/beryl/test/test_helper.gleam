//// Shared test helpers for beryl tests
////
//// Provides polling utilities to replace fragile `process.sleep()` calls
//// with deterministic condition-based waiting, plus a palabres log-capture
//// harness (backed by the `beryl_log_capture` Erlang test handler) used to
//// observe runtime-side logging as a proxy for "did the decoded envelope
//// reach the runtime", where reply presence/absence alone cannot
//// distinguish edge-level shedding from runtime-level shedding.

import beryl/presence
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleeunit/should

@external(erlang, "beryl_test_process_ffi", "mailbox_length")
pub fn mailbox_length(pid: process.Pid) -> Int

@external(erlang, "beryl_test_process_ffi", "monitor_count")
pub fn monitor_count(pid: process.Pid) -> Int

@external(erlang, "beryl_test_process_ffi", "monitored_by_count")
pub fn monitored_by_count(pid: process.Pid) -> Int

@external(erlang, "beryl_test_process_ffi", "suspend_process")
pub fn suspend_process(pid: process.Pid) -> Nil

@external(erlang, "beryl_test_process_ffi", "resume_process")
pub fn resume_process(pid: process.Pid) -> Nil

/// Run exact mailbox assertions apart from prior fixtures' delayed messages.
pub fn with_isolated_caller(timeout_ms: Int, action: fn() -> Nil) -> Nil {
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
  let outcome = process.selector_receive(selector, timeout_ms)

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
/// wait_until(
///   fn() { list.length(presence.list(tracker1, "room:lobby")) == 2 },
///   2000,
///   20,
/// )
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

@external(erlang, "beryl_log_capture", "with_capture")
fn with_capture_ffi(action: fn() -> a) -> a

/// Capture logs with test-owned host verbosity, restoring it even on failure.
pub fn with_capture(action: fn(process.Selector(CapturedLog)) -> a) -> a {
  use <- with_capture_ffi()
  let selector = captured_selector()
  drain(selector)
  action(selector)
}

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

// ── Presence actor lifetime ──────────────────────────────────────────────────

/// Kill a presence actor's process, simulating a crash without cleanup.
pub fn kill_presence(tracker: presence.Presence) -> Nil {
  let assert Ok(pid) = process.subject_owner(presence.subject(tracker))
  // The actor is linked to this (test) process; unlink before killing so
  // the exit signal does not take the test runner down with it.
  process.unlink(pid)
  process.kill(pid)
  // Wait for the process to actually be gone.
  wait_until(fn() { !process.is_alive(pid) }, 1000, 5)
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
