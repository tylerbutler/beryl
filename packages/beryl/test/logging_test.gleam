import app_test_helper
import beryl
import beryl/internal
import beryl/log
import beryl/socket.{AcceptJoin, Binary, Closed, Info, Join, Message, Next}
import beryl/transport
import beryl/transport/server
import beryl/wire
import gleam/dict
import gleam/erlang/process
import gleam/option
import gleeunit/should
import test_helper.{type CapturedLog}
import unitest

// Opaque Erlang-owned snapshots/references never masquerade as Gleam records.
type HostLogger

type HostSnapshot

@external(erlang, "beryl_logger_test_ffi", "with_host")
fn with_host(level: log.Level, action: fn(HostLogger) -> a) -> a

@external(erlang, "beryl_logger_test_ffi", "snapshot")
fn host_snapshot() -> HostSnapshot

@external(erlang, "beryl_logger_test_ffi", "with_cleanup")
fn with_cleanup(cleanup: fn() -> Nil, action: fn() -> a) -> a

@external(erlang, "beryl_logger_test_ffi", "receive_log")
fn receive_host_log(
  host: HostLogger,
  message: String,
  key: String,
  value: String,
  timeout: Int,
) -> Bool

@external(erlang, "beryl_logger_test_ffi", "receive_supervisor_report")
fn receive_supervisor_report(host: HostLogger, child: process.Pid) -> Bool

@external(erlang, "beryl_logger_test_ffi", "assertion_fails")
fn assertion_fails(action: fn() -> Nil) -> Bool

pub fn host_fixture_restores_configuration_after_assertion_failure_test() -> Nil {
  use <- unitest.tag("serial")
  let before = host_snapshot()
  assertion_fails(fn() {
    use _host <- with_host(log.Debug)
    should.fail()
  })
  |> should.be_true
  host_snapshot() |> should.equal(before)
}

pub fn capture_restores_configuration_after_assertion_failure_test() -> Nil {
  use <- unitest.tag("serial")
  let before = host_snapshot()
  assertion_fails(fn() {
    use _selector <- test_helper.with_capture()
    should.fail()
  })
  |> should.be_true
  host_snapshot() |> should.equal(before)
}

fn with_app(level: beryl.LogLevel, action: fn(beryl.Sockets) -> a) -> a {
  let channels =
    start_accepting_app(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_logging(beryl.logging_config(level, False)),
    )
  use <- with_cleanup(fn() {
    let _ = beryl.stop(channels)
    Nil
  })
  action(channels)
}

fn connect_and_join(channels: beryl.Sockets, socket_id: String) -> Nil {
  let frames = app_test_helper.connect(channels, socket_id)
  app_test_helper.join_ok(
    channels,
    frames,
    socket_id,
    "room:logging",
    "join-ref",
    "ref",
  )
  Nil
}

fn restart_runtime(channels: beryl.Sockets) -> process.Pid {
  let previous = app_test_helper.runtime_pid(channels)
  process.kill(previous)
  test_helper.wait_until(
    fn() {
      case beryl.app_runtime_pid(channels) {
        Ok(current) -> current != previous
        Error(Nil) -> False
      }
    },
    2000,
    5,
  )
  previous
}

pub fn start_and_restart_preserve_host_logger_configuration_test() -> Nil {
  use <- unitest.tag("serial")
  use _host <- with_host(log.Warn)
  let before = host_snapshot()
  use channels <- with_app(beryl.DebugLevel)

  // Includes sentinel primary level/filters/metadata, every handler config,
  // and the default handler process identity. No Palabres handler may appear.
  host_snapshot() |> should.equal(before)
  let _previous = restart_runtime(channels)
  connect_and_join(channels, "preserved-after-restart")
  host_snapshot() |> should.equal(before)
}

pub fn independent_runtime_thresholds_survive_start_and_restart_test() -> Nil {
  use <- unitest.tag("serial")
  use host <- with_host(log.Debug)
  use debug <- with_app(beryl.DebugLevel)
  use quiet <- with_app(beryl.ErrorLevel)

  // Starting Error second must neither silence Debug nor inherit its level.
  connect_and_join(debug, "debug-before")
  connect_and_join(quiet, "quiet-before")
  receive_host_log(host, "Join delivered", "socket_id", "debug-before", 1000)
  |> should.be_true
  receive_host_log(host, "Join delivered", "socket_id", "quiet-before", 0)
  |> should.be_false
  receive_host_log(host, "Socket connected", "socket_id", "quiet-before", 0)
  |> should.be_false

  // Restarting Debug last must not make the existing Error runtime verbose.
  let _previous = restart_runtime(debug)
  connect_and_join(debug, "debug-after")
  connect_and_join(quiet, "quiet-after")
  receive_host_log(host, "Join delivered", "socket_id", "debug-after", 1000)
  |> should.be_true
  receive_host_log(host, "Join delivered", "socket_id", "quiet-after", 0)
  |> should.be_false
  receive_host_log(host, "Socket connected", "socket_id", "quiet-after", 0)
  |> should.be_false
}

pub fn host_warning_threshold_wins_over_local_debug_test() -> Nil {
  use <- unitest.tag("serial")
  use host <- with_host(log.Warn)
  use channels <- with_app(beryl.DebugLevel)
  connect_and_join(channels, "host-filtered")

  // Positive control: host warning permits the startup warning, proving the
  // handler works even though debug and info are rejected by the host.
  receive_host_log(
    host,
    "No abuse controls configured",
    "logger",
    "beryl",
    1000,
  )
  |> should.be_true
  receive_host_log(host, "Join delivered", "socket_id", "host-filtered", 0)
  |> should.be_false
  receive_host_log(host, "Socket connected", "socket_id", "host-filtered", 0)
  |> should.be_false
}

pub fn otp_supervisor_report_remains_observable_test() -> Nil {
  use <- unitest.tag("serial")
  use host <- with_host(log.Debug)
  use channels <- with_app(beryl.ErrorLevel)
  let previous = restart_runtime(channels)

  // This is the real OTP supervisor report for the killed runtime, not a
  // manually emitted lookalike. Correlate it by the exact child pid.
  receive_supervisor_report(host, previous) |> should.be_true
}

fn with_transport(
  channels: beryl.Sockets,
  name: String,
  action: fn(server.ConnectionState) -> a,
) -> a {
  let assert Ok(permit) =
    transport.acquire_connection_slot(channels, "127.0.0.1")
  let #(state, selector) =
    server.init_connection(
      sockets: channels,
      seed: socket.empty_seed(),
      connection_permit: permit,
      base_selector: process.new_selector(),
      config: server.default_config("/socket"),
      force_close: fn() { Ok(Nil) },
      logger_name: name,
      telemetry: transport.telemetry(channels, transport.Mist),
      codec: option.None,
    )
  use <- with_cleanup(fn() {
    // These decoder-only fixtures enqueue no outbound frames. Closing cancels
    // the budget (so shutdown cannot enqueue a transport Close), then stopping
    // this fixture's system produces the exact monitored owner's DOWN.
    server.close_connection(state)
    let _ = beryl.stop(channels)
    process.selector_receive(selector, 1000) |> should.equal(Ok(server.Close))
  })
  action(state)
}

pub fn transport_fixture_restores_monitor_and_mailbox_baselines_test() -> Nil {
  use <- unitest.tag("serial")
  let caller = process.self()
  // An unrelated message must survive both cleanup paths.
  let unrelated = process.new_subject()
  process.send(unrelated, "keep")
  let monitors_before = test_helper.monitor_count(caller)
  let mailbox_before = test_helper.mailbox_length(caller)

  with_app(beryl.ErrorLevel, fn(channels) {
    with_transport(channels, "successful-cleanup", fn(_state) { Nil })
  })
  test_helper.monitor_count(caller) |> should.equal(monitors_before)
  test_helper.mailbox_length(caller) |> should.equal(mailbox_before)

  assertion_fails(fn() {
    use channels <- with_app(beryl.ErrorLevel)
    use _state <- with_transport(channels, "failed-cleanup")
    should.fail()
  })
  |> should.be_true
  test_helper.monitor_count(caller) |> should.equal(monitors_before)
  test_helper.mailbox_length(caller) |> should.equal(mailbox_before)
  process.receive(unrelated, 0) |> should.equal(Ok("keep"))
}

pub fn shared_transport_uses_own_runtime_threshold_test() -> Nil {
  use <- unitest.tag("serial")
  use host <- with_host(log.Debug)
  use debug <- with_app(beryl.DebugLevel)
  use quiet <- with_app(beryl.ErrorLevel)
  use debug_connection <- with_transport(debug, "debug-transport")
  use quiet_connection <- with_transport(quiet, "quiet-transport")

  // Decode and warning emission are synchronous in the calling transport.
  let assert server.Continue(_) =
    server.handle_text_frame(debug_connection, "not-json")
  let assert server.Continue(_) =
    server.handle_text_frame(quiet_connection, "not-json")
  receive_host_log(
    host,
    "Failed to decode wire protocol message",
    "logger",
    "debug-transport",
    0,
  )
  |> should.be_true
  receive_host_log(
    host,
    "Failed to decode wire protocol message",
    "logger",
    "quiet-transport",
    0,
  )
  |> should.be_false
}

fn get_metadata(captured: CapturedLog, key: String) -> Result(String, Nil) {
  dict.get(captured.metadata, key)
}

/// A start_app system that accepts every join, with the given config.
fn start_accepting_app(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      config,
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, option.None)])
          Message(_, _, _, _) | Binary(_, _) | Closed(_, _) | Info(_) ->
            Next(model, [])
        }
      },
    )
  channels
}

pub fn start_app_accepts_debug_logging_config_test() -> Nil {
  use <- unitest.tag("serial")
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
      level: log.Debug,
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
      level: log.Debug,
      include_payloads: True,
      payload_preview_bytes: 3,
    )

  internal.preview_metadata("payload_preview", "abcdef", logging)
  |> should.equal([#("payload_preview", "abc")])
}

pub fn debug_join_log_carries_metadata_without_payload_preview_test() -> Nil {
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()

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
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()

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
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()

  let channels = start_accepting_app(beryl.config(wire.phoenix_codec()))

  test_helper.receive_log(selector, "No abuse controls configured", 10)
  |> should.be_ok

  let _ = beryl.stop(channels)
  test_helper.stop_capture()
}

pub fn start_app_does_not_warn_when_a_limit_is_configured_test() -> Nil {
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()

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
