import beryl
import beryl/channel
import beryl/coordinator
import beryl/internal
import beryl/wire
import birch
import birch/handler
import birch/level
import birch/record.{type LogRecord}
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
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

  let assert Ok(channels) = beryl.start(config)

  channels.config.logging.level
  |> should.equal(beryl.Debug)
  channels.config.logging.include_payloads
  |> should.be_false
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
  let logs = process.new_subject()
  birch.configure([
    birch.config_level(level.Debug),
    birch.config_handlers([
      handler.new_with_record_write(name: "test-capture", write: fn(log_record) {
        process.send(logs, log_record)
      }),
    ]),
  ])

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.Debug,
      include_payloads: False,
    ))
  let assert Ok(channels) = beryl.start(config)

  process.send(
    channels.coordinator,
    coordinator.SocketConnected("logging-socket", fn(_) { Ok(Nil) }, fn(_) {
      Ok(Nil)
    }),
  )
  coordinator.route_message(
    channels.coordinator,
    "logging-socket",
    "[null,\"ref\",\"room:lobby\",\"phx_join\",{\"secret\":\"token\"}]",
  )

  let assert Ok(log_record) =
    receive_log(logs, "Inbound text frame decoded", 10)
  log_record.logger_name
  |> should.equal("beryl.coordinator")
  record.get_metadata(log_record, "socket_id")
  |> should.equal(Ok("logging-socket"))
  record.get_metadata(log_record, "topic")
  |> should.equal(Ok("room:lobby"))
  record.get_metadata(log_record, "frame_preview")
  |> should.equal(Error(Nil))
}

pub fn debug_join_missing_handler_logs_routing_and_send_test() {
  let logs = process.new_subject()
  birch.configure([
    birch.config_level(level.Debug),
    birch.config_handlers([
      handler.new_with_record_write(name: "test-capture", write: fn(log_record) {
        process.send(logs, log_record)
      }),
    ]),
  ])

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.Debug,
      include_payloads: False,
    ))
  let assert Ok(channels) = beryl.start(config)

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "missing-handler-socket",
      fn(_) { Ok(Nil) },
      fn(_) { Ok(Nil) },
    ),
  )
  coordinator.route_message(
    channels.coordinator,
    "missing-handler-socket",
    "[null,\"ref\",\"room:missing\",\"phx_join\",{}]",
  )

  let assert Ok(missing_log) = receive_log(logs, "Join handler missing", 10)
  record.get_metadata(missing_log, "socket_id")
  |> should.equal(Ok("missing-handler-socket"))
  record.get_metadata(missing_log, "topic")
  |> should.equal(Ok("room:missing"))

  let assert Ok(send_log) = receive_log(logs, "Outbound frame sent", 10)
  record.get_metadata(send_log, "socket_id")
  |> should.equal(Ok("missing-handler-socket"))
  record.get_metadata(send_log, "topic")
  |> should.equal(Ok("room:missing"))
  record.get_metadata(send_log, "frame_kind")
  |> should.equal(Ok("text"))
}

pub fn debug_channel_callback_logs_push_result_test() {
  let logs = process.new_subject()
  birch.configure([
    birch.config_level(level.Debug),
    birch.config_handlers([
      handler.new_with_record_write(name: "test-capture", write: fn(log_record) {
        process.send(logs, log_record)
      }),
    ]),
  ])

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
  beryl.register(channels, "room:*", handler)
  |> should.equal(Ok(Nil))

  process.send(
    channels.coordinator,
    coordinator.SocketConnected("callback-log-socket", fn(_) { Ok(Nil) }, fn(_) {
      Ok(Nil)
    }),
  )
  coordinator.route_message(
    channels.coordinator,
    "callback-log-socket",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )
  coordinator.route_message(
    channels.coordinator,
    "callback-log-socket",
    "[\"join-ref\",\"msg-ref\",\"room:lobby\",\"client_event\",{}]",
  )

  let assert Ok(push_log) =
    receive_log(logs, "Channel callback returned push", 20)
  record.get_metadata(push_log, "socket_id")
  |> should.equal(Ok("callback-log-socket"))
  record.get_metadata(push_log, "topic")
  |> should.equal(Ok("room:lobby"))
  record.get_metadata(push_log, "event")
  |> should.equal(Ok("client_event"))
}

fn receive_log(
  logs: process.Subject(LogRecord),
  message: String,
  attempts: Int,
) -> Result(LogRecord, Nil) {
  case attempts <= 0 {
    True -> Error(Nil)
    False -> {
      case process.receive(logs, 500) {
        Ok(log_record) -> {
          case log_record.message == message {
            True -> Ok(log_record)
            False -> receive_log(logs, message, attempts - 1)
          }
        }
        Error(_) -> Error(Nil)
      }
    }
  }
}
