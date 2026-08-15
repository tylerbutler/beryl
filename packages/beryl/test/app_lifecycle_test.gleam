//// Core lifecycle contract for app-side dispatch systems (ADR 0002 phase 2,
//// task 1): eager config validation shared by `start` and `child_spec`,
//// a stable non-generic handle usable before startup, name-backed pre-start
//// admission/dispatch that degrades to no-ops rather than crashing, and
//// idempotent `stop`.

import app_test_helpers as h
import beryl
import beryl/wire
import gleam/otp/static_supervisor
import gleam/string
import gleeunit
import gleeunit/should
import test_helpers

pub fn main() {
  gleeunit.main()
}

// A control character (U+0001) that topic-pattern validation rejects.
const control_char = "\u{0001}"

// ── validate_config ─────────────────────────────────────────────────────────

pub fn validate_config_accepts_default_test() {
  beryl.config(wire.phoenix_codec())
  |> beryl.validate_config
  |> should.equal(Ok(Nil))
}

pub fn validate_config_rejects_low_heartbeat_test() {
  beryl.config(wire.phoenix_codec())
  |> beryl.with_heartbeat(timeout_ms: 1)
  |> beryl.validate_config
  |> should.equal(Error(beryl.HeartbeatTimeoutTooLow(2)))
}

pub fn validate_config_accepts_valid_topic_pattern_test() {
  beryl.config(wire.phoenix_codec())
  |> beryl.with_topic_rate(pattern: "room:*", per_second: 5, burst: 10)
  |> beryl.validate_config
  |> should.equal(Ok(Nil))
}

pub fn validate_config_rejects_invalid_topic_pattern_test() {
  let bad = "room:" <> control_char
  let result =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_topic_rate(pattern: bad, per_second: 5, burst: 10)
    |> beryl.validate_config

  case result {
    Error(beryl.InvalidTopicPattern(pattern, _reason)) ->
      pattern |> should.equal(bad)
    _ -> should.fail()
  }
}

// ── start / child_spec config validation parity ────────────────────────

pub fn start_rejects_invalid_config_test() {
  h.start_app(
    beryl.config(wire.phoenix_codec())
      |> beryl.with_heartbeat(timeout_ms: 1),
    init: h.accepting_init,
    update: h.accepting_update,
  )
  |> should.equal(Error(beryl.HeartbeatTimeoutTooLow(2)))
}

pub fn validate_config_rejects_invalid_disabled_topic_pattern_test() {
  let bad = "room:" <> control_char
  let result =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_topic_rate(pattern: bad, per_second: 0, burst: 0)
    |> beryl.validate_config

  case result {
    Error(beryl.InvalidTopicPattern(pattern, _reason)) ->
      pattern |> should.equal(bad)
    _ -> should.fail()
  }
}

pub fn child_spec_rejects_invalid_config_test() {
  let result =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_topic_rate(
          pattern: "room:" <> control_char,
          per_second: 5,
          burst: 10,
        ),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  case result {
    Error(beryl.InvalidTopicPattern(_, _)) -> Nil
    _ -> should.fail()
  }
}

// ── child_spec handle lifecycle ────────────────────────────────────────────

pub fn child_spec_handle_is_usable_before_and_after_start_test() {
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  // Before the owning supervisor starts, the runtime is not running: the
  // handle reports no runtime pid and pre-start dispatch is a quiet no-op
  // (this call must not crash).
  beryl.app_runtime_pid(sockets) |> should.be_error
  h.route(sockets, "s0", "[null,\"r-0\",\"room:a\",\"noop\",{}]")

  // Start the application's own supervisor with the returned child spec.
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()

  // The same handle is now backed by a live runtime and serves sockets.
  test_helpers.wait_until(
    fn() {
      case beryl.app_runtime_pid(sockets) {
        Ok(_) -> True
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  let frames = h.connect(sockets, "s1")
  h.join(sockets, "s1", "room:a", "jr-1", "r-1")
  h.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
}

// ── stop idempotence ───────────────────────────────────────────────────────

pub fn stop_is_idempotent_test() {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  beryl.stop(sockets) |> should.equal(Ok(Nil))
  // A second stop after the runtime is already down is safe and reports
  // NotRunning rather than crashing.
  beryl.stop(sockets) |> should.equal(Error(beryl.NotRunning))
}

pub fn stop_before_start_returns_not_running_test() {
  let assert Ok(#(sockets, _spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  // The subtree was never started, so stop is a safe no-op.
  beryl.stop(sockets) |> should.equal(Error(beryl.NotRunning))
}

pub fn child_spec_admission_fails_before_start_test() {
  let assert Ok(#(sockets, _spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(1),
      init: h.accepting_init,
      update: h.accepting_update,
    )

  // The limiter is supervised inside the not-yet-started subtree, so
  // admission fails cleanly rather than panicking.
  beryl.acquire_connection_slot(sockets, "1.2.3.4")
  |> should.be_error
}
