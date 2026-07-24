//// Logging contracts for app-side dispatch, observed through the palabres
//// capture handler: `start` warns once when no abuse controls are
//// configured and stays quiet when a limit is set, and the runtime's inbound
//// routing log records socket/topic/event metadata without ever logging the
//// message payload by default.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Next}
import beryl/wire
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

type CapturedLog {
  CapturedLog(message: String, metadata: dict.Dict(String, String))
}

@external(erlang, "beryl_log_capture", "start")
fn start_capture(pid: process.Pid) -> Nil

@external(erlang, "beryl_log_capture", "stop")
fn stop_capture() -> Nil

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

fn begin_capture() -> process.Selector(CapturedLog) {
  start_capture(process.self())
  let selector = captured_selector()
  drain(selector)
  selector
}

fn drain(selector: process.Selector(CapturedLog)) -> Nil {
  case process.selector_receive(selector, 0) {
    Ok(_) -> drain(selector)
    Error(Nil) -> Nil
  }
}

fn receive_log(
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

pub fn start_warns_when_no_abuse_controls_configured_test() {
  let selector = begin_capture()

  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, _ev: event.Input(Nil)) { Next(model, []) },
    )

  receive_log(selector, "No abuse controls configured", 10)
  |> should.be_ok

  let _ = beryl.stop(channels)
  stop_capture()
}

pub fn start_does_not_warn_when_a_limit_is_configured_test() {
  let selector = begin_capture()

  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_message_rate(per_second: 100, burst: 200),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, _ev: event.Input(Nil)) { Next(model, []) },
    )

  receive_log(selector, "No abuse controls configured", 2)
  |> should.be_error

  let _ = beryl.stop(channels)
  stop_capture()
}

pub fn inbound_routing_log_omits_payload_by_default_test() {
  let selector = begin_capture()

  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_logging(beryl.logging_config(
          level: beryl.DebugLevel,
          include_payloads: False,
        )),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          _ -> Next(model, [])
        }
      },
    )
  let frames = h.connect(channels, "log-socket")
  h.join(channels, "log-socket", "room:lobby", "jr-1", "r-1")
  let _reply = h.recv(frames)
  h.push(channels, "log-socket", "room:lobby", "client_event", "msg-ref")

  let assert Ok(routed) = receive_log(selector, "Inbound message routed", 20)
  routed.metadata |> dict.get("socket_id") |> should.equal(Ok("log-socket"))
  routed.metadata |> dict.get("topic") |> should.equal(Ok("room:lobby"))
  routed.metadata |> dict.get("event") |> should.equal(Ok("client_event"))
  // The payload is never logged by default.
  routed.metadata |> dict.get("frame_preview") |> should.equal(Error(Nil))
  routed.metadata |> dict.get("payload") |> should.equal(Error(Nil))

  let _ = beryl.stop(channels)
  stop_capture()
}
