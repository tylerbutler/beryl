import app_test_helper
import beryl
import beryl/internal
import beryl/socket.{AcceptJoin, Join, Next}
import beryl/wire
import gleam/dict
import gleam/option
import gleeunit/should
import test_helper.{type CapturedLog}

fn get_metadata(captured: CapturedLog, key: String) -> Result(String, Nil) {
  dict.get(captured.metadata, key)
}

/// A start_app system that accepts every join, with the given config.
fn start_accepting_app(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      config,
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, option.None)])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

pub fn start_app_accepts_debug_logging_config_test() -> Nil {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.DebugLevel,
      include_payloads: False,
    ))

  let channels = start_accepting_app(config)
  let _ = beryl.stop(channels)
  Nil
}

pub fn preview_metadata_omits_payloads_by_default_test() -> Nil {
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

pub fn preview_metadata_bounds_payloads_when_enabled_test() -> Nil {
  let logging =
    internal.LoggingConfig(
      level: internal.Debug,
      include_payloads: True,
      payload_preview_bytes: 3,
    )

  internal.preview_metadata("payload_preview", "abcdef", logging)
  |> should.equal([#("payload_preview", "abc")])
}

pub fn debug_join_log_carries_metadata_without_payload_preview_test() -> Nil {
  let selector = test_helper.begin_capture()

  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.DebugLevel,
      include_payloads: False,
    ))
  let channels = start_accepting_app(config)

  let frames = app_test_helper.connect(channels, "logging-socket")
  app_test_helper.join(channels, "logging-socket", "room:lobby", "j1", "j1")
  let _join_reply = app_test_helper.recv(frames)

  let assert Ok(captured) =
    test_helper.receive_log(selector, "Join delivered", 20)
  get_metadata(captured, "logger")
  |> should.equal(Ok("beryl.runtime"))
  get_metadata(captured, "socket_id")
  |> should.equal(Ok("logging-socket"))
  get_metadata(captured, "topic")
  |> should.equal(Ok("room:lobby"))
  get_metadata(captured, "payload_preview")
  |> should.equal(Error(Nil))

  let _ = beryl.stop(channels)
  test_helper.stop_capture()
}

pub fn socket_connected_is_logged_with_socket_id_test() -> Nil {
  let selector = test_helper.begin_capture()

  let channels =
    start_accepting_app(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 100, burst: 200),
    )
  let _frames = app_test_helper.connect(channels, "log-connect-socket")

  let assert Ok(captured) =
    test_helper.receive_log(selector, "Socket connected", 20)
  get_metadata(captured, "socket_id")
  |> should.equal(Ok("log-connect-socket"))

  let _ = beryl.stop(channels)
  test_helper.stop_capture()
}

pub fn start_app_warns_when_no_abuse_controls_configured_test() -> Nil {
  let selector = test_helper.begin_capture()

  let channels = start_accepting_app(beryl.config(wire.phoenix_codec()))

  test_helper.receive_log(selector, "No abuse controls configured", 10)
  |> should.be_ok

  let _ = beryl.stop(channels)
  test_helper.stop_capture()
}

pub fn start_app_does_not_warn_when_a_limit_is_configured_test() -> Nil {
  let selector = test_helper.begin_capture()

  let channels =
    start_accepting_app(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 100, burst: 200),
    )

  test_helper.receive_log(selector, "No abuse controls configured", 2)
  |> should.be_error

  let _ = beryl.stop(channels)
  test_helper.stop_capture()
}
