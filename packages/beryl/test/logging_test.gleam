import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Next}
import beryl/internal
import beryl/wire
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

/// A captured palabres log forwarded by `beryl_log_capture`. The field order
/// matches the `{captured_log, Message, Metadata}` tuple the handler sends.
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

fn get_metadata(captured: CapturedLog, key: String) -> Result(String, Nil) {
  dict.get(captured.metadata, key)
}

/// Begin capturing into the current process and discard any logs left in the
/// mailbox by a previous test (gleeunit runs tests in a shared process).
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

/// A start_app system that accepts every join, with the given config.
fn start_accepting_app(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
      config,
      init: fn(_info: event.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, option.None)])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

pub fn default_logging_preserves_info_without_payloads_test() {
  let config = beryl.config(wire.phoenix_codec())

  let logging = beryl.config_logging(config)
  beryl.logging_level(logging)
  |> should.equal(beryl.InfoLevel)
  beryl.logging_include_payloads(logging)
  |> should.be_false
  beryl.logging_payload_preview_bytes(logging)
  |> should.equal(200)
}

pub fn with_logging_replaces_logging_config_test() {
  let logging =
    beryl.logging_config(level: beryl.ErrorLevel, include_payloads: True)
    |> beryl.with_payload_preview_bytes(bytes: 64)

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(logging)

  let logging = beryl.config_logging(config)
  beryl.logging_level(logging)
  |> should.equal(beryl.ErrorLevel)
  beryl.logging_include_payloads(logging)
  |> should.be_true
  beryl.logging_payload_preview_bytes(logging)
  |> should.equal(64)
}

pub fn start_app_accepts_debug_logging_config_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.DebugLevel,
      include_payloads: False,
    ))

  let channels = start_accepting_app(config)
  let _ = beryl.stop(channels)
}

pub fn payload_preview_bytes_never_negative_test() {
  let logging =
    beryl.logging_config(level: beryl.DebugLevel, include_payloads: True)
    |> beryl.with_payload_preview_bytes(bytes: -1)

  beryl.logging_payload_preview_bytes(logging)
  |> should.equal(0)
}

pub fn preview_metadata_omits_payloads_by_default_test() {
  let logging =
    internal.LoggingConfig(
      level: internal.Debug,
      include_payloads: False,
      payload_preview_bytes: 200,
    )

  internal.preview_metadata(
    "payload_preview",
    "{\"secret\":\"token\"}",
    logging,
  )
  |> should.equal([])
}

pub fn preview_metadata_bounds_payloads_when_enabled_test() {
  let logging =
    internal.LoggingConfig(
      level: internal.Debug,
      include_payloads: True,
      payload_preview_bytes: 3,
    )

  internal.preview_metadata("payload_preview", "abcdef", logging)
  |> should.equal([#("payload_preview", "abc")])
}

pub fn debug_join_log_carries_metadata_without_payload_preview_test() {
  let selector = begin_capture()

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.DebugLevel,
      include_payloads: False,
    ))
  let channels = start_accepting_app(config)

  let frames = h.connect(channels, "logging-socket")
  h.join(channels, "logging-socket", "room:lobby", "j1", "j1")
  let _join_reply = h.recv(frames)

  let assert Ok(captured) = receive_log(selector, "Join delivered", 20)
  get_metadata(captured, "logger")
  |> should.equal(Ok("beryl.runtime"))
  get_metadata(captured, "socket_id")
  |> should.equal(Ok("logging-socket"))
  get_metadata(captured, "topic")
  |> should.equal(Ok("room:lobby"))
  get_metadata(captured, "payload_preview")
  |> should.equal(Error(Nil))

  let _ = beryl.stop(channels)
  stop_capture()
}

pub fn socket_connected_is_logged_with_socket_id_test() {
  let selector = begin_capture()

  let channels =
    start_accepting_app(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 100, burst: 200),
    )
  let _frames = h.connect(channels, "log-connect-socket")

  let assert Ok(captured) = receive_log(selector, "Socket connected", 20)
  get_metadata(captured, "socket_id")
  |> should.equal(Ok("log-connect-socket"))

  let _ = beryl.stop(channels)
  stop_capture()
}

pub fn start_app_warns_when_no_abuse_controls_configured_test() {
  let selector = begin_capture()

  let channels = start_accepting_app(beryl.config(wire.phoenix_codec()))

  receive_log(selector, "No abuse controls configured", 10)
  |> should.be_ok

  let _ = beryl.stop(channels)
  stop_capture()
}

pub fn start_app_does_not_warn_when_a_limit_is_configured_test() {
  let selector = begin_capture()

  let channels =
    start_accepting_app(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 100, burst: 200),
    )

  receive_log(selector, "No abuse controls configured", 2)
  |> should.be_error

  let _ = beryl.stop(channels)
  stop_capture()
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
