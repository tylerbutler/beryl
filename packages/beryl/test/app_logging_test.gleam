//// Logging contracts for app-side dispatch, observed through the palabres
//// capture handler: `start` warns once when no abuse controls are
//// configured and stays quiet when a limit is set, and the runtime's inbound
//// routing log records socket/topic/event metadata without ever logging the
//// message payload by default.

import app_test_helper
import beryl
import beryl/internal
import beryl/socket.{AcceptJoin, Join, Next}
import beryl/wire
import gleam/dict
import gleam/option.{None}
import gleeunit/should
import test_helper

/// Palabres's level is a global, singleton setting (see
/// `beryl/internal.configure`); restore it to beryl's own default so a
/// `DebugLevel` test doesn't leak verbosity into tests that run after it.
fn restore_default_logging_level() -> Nil {
  internal.configure(internal.LoggingConfig(
    level: internal.Info,
    include_payloads: False,
    payload_preview_bytes: 200,
  ))
}

pub fn start_warns_when_no_abuse_controls_configured_test() -> Nil {
  let selector = test_helper.begin_capture()

  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, _ev: socket.Input(Nil)) { Next(model, []) },
    )

  test_helper.receive_log(selector, "No abuse controls configured", 10)
  |> should.be_ok

  let _ = beryl.stop(channels)
  test_helper.stop_capture()
}

pub fn start_does_not_warn_when_a_limit_is_configured_test() -> Nil {
  let selector = test_helper.begin_capture()

  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_message_rate(per_second: 100, burst: 200),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, _ev: socket.Input(Nil)) { Next(model, []) },
    )

  test_helper.receive_log(selector, "No abuse controls configured", 2)
  |> should.be_error

  let _ = beryl.stop(channels)
  test_helper.stop_capture()
}

pub fn inbound_routing_log_omits_payload_by_default_test() -> Nil {
  let selector = test_helper.begin_capture()

  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_logging(beryl.logging_config(
          level: beryl.DebugLevel,
          include_payloads: False,
        )),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          socket.Message(..)
          | socket.Binary(..)
          | socket.Closed(..)
          | socket.Info(..) -> Next(model, [])
        }
      },
    )
  let frames = app_test_helper.connect(channels, "log-socket")
  app_test_helper.join(channels, "log-socket", "room:lobby", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  app_test_helper.push(
    channels,
    "log-socket",
    "room:lobby",
    "client_event",
    "message-ref",
  )

  let assert Ok(routed) =
    test_helper.receive_log(selector, "Inbound message routed", 20)
  routed.metadata |> dict.get("socket_id") |> should.equal(Ok("log-socket"))
  routed.metadata |> dict.get("topic") |> should.equal(Ok("room:lobby"))
  routed.metadata |> dict.get("event") |> should.equal(Ok("client_event"))
  // The payload is never logged by default.
  routed.metadata |> dict.get("frame_preview") |> should.equal(Error(Nil))
  routed.metadata |> dict.get("payload") |> should.equal(Error(Nil))

  let _ = beryl.stop(channels)
  test_helper.stop_capture()
  restore_default_logging_level()
}
