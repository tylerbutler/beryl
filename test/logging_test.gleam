import beryl
import beryl/channel
import beryl/coordinator
import beryl/internal
import beryl/wire
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
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

pub fn default_logging_preserves_info_without_payloads_test() {
  let config = beryl.config(wire.phoenix_codec())

  config.logging.level
  |> should.equal(beryl.Info)
  config.logging.include_payloads
  |> should.be_false
  config.logging.payload_preview_bytes
  |> should.equal(200)
}

pub fn with_logging_replaces_logging_config_test() {
  let logging =
    beryl.logging_config(level: beryl.Debug, include_payloads: True)
    |> beryl.with_payload_preview_bytes(bytes: 64)

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(logging)

  config.logging.level
  |> should.equal(beryl.Debug)
  config.logging.include_payloads
  |> should.be_true
  config.logging.payload_preview_bytes
  |> should.equal(64)
}

pub fn channels_start_accepts_debug_logging_config_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.Debug,
      include_payloads: False,
    ))

  beryl.start(config)
  |> should.be_ok
}

pub fn coordinator_config_has_safe_logging_defaults_test() {
  let config = coordinator.config(wire.phoenix_codec())

  config.logging.level
  |> should.equal(coordinator.Info)
  config.logging.include_payloads
  |> should.be_false
  config.logging.payload_preview_bytes
  |> should.equal(200)
}

pub fn payload_preview_bytes_never_negative_test() {
  let logging =
    beryl.logging_config(level: beryl.Debug, include_payloads: True)
    |> beryl.with_payload_preview_bytes(bytes: -1)

  logging.payload_preview_bytes
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

pub fn debug_decode_log_omits_frame_preview_by_default_test() {
  let selector = begin_capture()

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.Debug,
      include_payloads: False,
    ))
  let assert Ok(channels) = beryl.start(config)

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "logging-socket",
      fn(_) { Ok(Nil) },
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "logging-socket",
    "[\"join\\nref\",\"ref\\rfield\",\"room:lobby\",\"phx_join\",{\"secret\":\"token\"}]",
  )

  let assert Ok(captured) =
    receive_log(selector, "Inbound text frame decoded", 10)
  get_metadata(captured, "logger")
  |> should.equal(Ok("beryl.coordinator"))
  get_metadata(captured, "socket_id")
  |> should.equal(Ok("logging-socket"))
  get_metadata(captured, "topic")
  |> should.equal(Ok("room:lobby"))
  get_metadata(captured, "ref")
  |> should.equal(Ok("ref?field"))
  get_metadata(captured, "join_ref")
  |> should.equal(Ok("join?ref"))
  get_metadata(captured, "frame_preview")
  |> should.equal(Error(Nil))
  stop_capture()
}

pub fn debug_join_missing_handler_logs_routing_and_send_test() {
  let selector = begin_capture()

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.Debug,
      include_payloads: False,
    ))
  let assert Ok(channels) = beryl.start(config)

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "missing-handler-socket",
      fn(_) { Ok(Nil) },
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "missing-handler-socket",
    "[null,\"ref\",\"room:missing\",\"phx_join\",{}]",
  )

  let assert Ok(missing_log) = receive_log(selector, "Join handler missing", 10)
  get_metadata(missing_log, "socket_id")
  |> should.equal(Ok("missing-handler-socket"))
  get_metadata(missing_log, "topic")
  |> should.equal(Ok("room:missing"))

  let assert Ok(send_log) = receive_log(selector, "Outbound frame sent", 10)
  get_metadata(send_log, "socket_id")
  |> should.equal(Ok("missing-handler-socket"))
  get_metadata(send_log, "topic")
  |> should.equal(Ok("room:missing"))
  get_metadata(send_log, "frame_kind")
  |> should.equal(Ok("text"))
  stop_capture()
}

pub fn debug_channel_callback_logs_push_result_test() {
  let selector = begin_capture()

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.Debug,
      include_payloads: False,
    ))
  let assert Ok(channels) = beryl.start(config)
  let handler =
    channel.new(fn(_, _, socket) { channel.JoinOk(reply: None, socket: socket) })
    |> channel.with_handle_in(fn(_, _, socket) {
      channel.Push(
        event: "server_event",
        payload: json.object([]),
        socket: socket,
      )
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "callback-log-socket",
      fn(_) { Ok(Nil) },
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "callback-log-socket",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "callback-log-socket",
    "[\"join-ref\",\"msg-ref\",\"room:lobby\",\"client_event\",{}]",
  )

  let assert Ok(push_log) =
    receive_log(selector, "Channel callback returned push", 20)
  get_metadata(push_log, "socket_id")
  |> should.equal(Ok("callback-log-socket"))
  get_metadata(push_log, "topic")
  |> should.equal(Ok("room:lobby"))
  get_metadata(push_log, "event")
  |> should.equal(Ok("client_event"))
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
