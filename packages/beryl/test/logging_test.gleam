import app_test_helper
import beryl
import beryl/internal
import beryl/log
import beryl/socket.{AcceptJoin, Binary, Closed, Info, Join, Message, Next}
import beryl/transport
import beryl/transport/server
import beryl/wire
import beryl/wire/codec
import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
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
  with_config(
    beryl.config(wire.phoenix_codec())
      |> beryl.with_logging(beryl.logging_config(level, False)),
    action,
  )
}

fn with_config(config: beryl.Config, action: fn(beryl.Sockets) -> a) -> a {
  let channels = start_accepting_app(config)
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

  // Decode and diagnostic emission are synchronous in the calling transport.
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
      include_payloads: True,
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

pub fn diagnostic_fields_are_utf8_byte_bounded_and_sanitized_test() -> Nil {
  list.each(["a", "🌍", "é"], fn(character) {
    let bounded = log.field(string.repeat(character, 10_000))
    should.be_true(string.byte_size(bounded) <= 256)
    string.ends_with(bounded, "...") |> should.be_true
  })
  log.field(string.repeat("a", 256))
  |> should.equal(string.repeat("a", 256))
  log.field("line\n\r\t\u{0}\u{7f}\u{85}end")
  |> should.equal("line??????end")
}

pub fn disabled_debug_does_not_construct_metadata_test() -> Nil {
  use <- unitest.tag("serial")
  use _host <- with_host(log.Info)
  log.debug_lazy(log.new("host-filtered"), "unused", fn() {
    panic as "host-disabled debug constructed metadata"
  })
  log.debug_lazy(
    log.new("locally-filtered") |> log.with_level(log.Warn),
    "unused",
    fn() { panic as "locally-disabled debug constructed metadata" },
  )
}

pub fn crash_descriptions_keep_their_separate_bound_test() -> Nil {
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()
  let crash = string.repeat("context", 60) <> " application_callback:42"
  log.error(log.new("crash-format"), "Callback crash bound", [
    #("crash", crash),
  ])
  let assert Ok(captured) =
    test_helper.receive_log(selector, "Callback crash bound", 10)
  dict.get(captured.metadata, "crash") |> should.equal(Ok(crash))
}

fn rejecting_codec(reason: String) -> codec.Codec {
  let phoenix = wire.phoenix_codec()
  codec.new(
    decode_text: fn(_) { Error(codec.InvalidFormat(reason)) },
    encode_reply: codec.encode_reply(phoenix),
    encode_push: codec.encode_push(phoenix),
    encode_heartbeat_reply: codec.encode_heartbeat_reply(phoenix),
  )
  |> codec.with_binary_decoder(fn(_) { Error(codec.InvalidFormat(reason)) })
}

pub fn shared_decode_diagnostics_bound_codec_errors_for_text_and_binary_test() -> Nil {
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()
  let config =
    beryl.config(rejecting_codec(string.repeat("🌍\n", 10_000)))
    |> beryl.with_logging(beryl.logging_config(beryl.DebugLevel, False))
  use channels <- with_config(config)
  use state <- with_transport(channels, "bounded-codec")
  let assert server.Continue(_) = server.handle_text_frame(state, "bad")
  let assert server.Continue(_) = server.handle_binary_frame(state, <<0>>)
  list.each(
    [
      "Failed to decode wire protocol message",
      "Failed to decode binary wire protocol message",
    ],
    fn(message) {
      let assert Ok(captured) = test_helper.receive_log(selector, message, 30)
      let assert Ok(error) = dict.get(captured.metadata, "error")
      should.be_true(string.byte_size(error) <= 256)
      string.ends_with(error, "...") |> should.be_true
      string.contains(error, "\n") |> should.be_false
    },
  )
}

fn send_inbound(
  channels: beryl.Sockets,
  topic: String,
  kind: codec.InboundKind,
) -> Nil {
  transport.route_decoded(
    channels,
    "drops",
    codec.inbound(
      join_ref: option.None,
      ref: option.None,
      topic: topic,
      kind: kind,
      payload: dynamic.nil(),
    ),
  )
  |> should.equal(Ok(Nil))
}

pub fn runtime_validation_rejections_are_debug_and_fields_are_bounded_test() -> Nil {
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()
  use channels <- with_app(beryl.DebugLevel)
  let frames = app_test_helper.connect(channels, "drops")
  let oversized = string.repeat("🌍", 10_000)
  send_inbound(channels, oversized, codec.Join)
  let _reply = app_test_helper.recv(frames)
  send_inbound(channels, oversized, codec.Leave)
  send_inbound(channels, oversized, codec.Event(oversized))
  send_inbound(channels, "room:valid", codec.Event(oversized))
  list.each(
    [
      "Join rejected: invalid topic",
      "Leave dropped: invalid topic",
      "Event dropped: invalid topic",
      "Event dropped: invalid event",
    ],
    fn(message) {
      let assert Ok(captured) = test_helper.receive_log(selector, message, 30)
      list.each(["topic", "event"], fn(key) {
        case dict.get(captured.metadata, key) {
          Ok(value) -> should.be_true(string.byte_size(value) <= 256)
          Error(Nil) -> Nil
        }
      })
    },
  )
}

pub fn comparable_runtime_drops_use_debug_not_warning_test() -> Nil {
  use <- unitest.tag("serial")
  use host <- with_host(log.Debug)
  list.each([beryl.DebugLevel, beryl.InfoLevel], fn(level) {
    let config =
      beryl.config(wire.phoenix_codec())
      |> beryl.with_logging(beryl.logging_config(level, False))
    let enabled = level == beryl.DebugLevel
    with_config(config, fn(channels) {
      let frames = app_test_helper.connect(channels, "drops")
      send_inbound(channels, "", codec.Join)
      let _reply = app_test_helper.recv(frames)
      send_inbound(channels, "", codec.Leave)
      send_inbound(channels, "", codec.Event("message"))
      send_inbound(channels, "room:valid", codec.Event(""))
      send_inbound(channels, "room:unjoined", codec.Event("message"))
      list.each(
        [
          "Join rejected: invalid topic",
          "Leave dropped: invalid topic",
          "Event dropped: invalid topic",
          "Event dropped: invalid event",
          "Inbound message rejected",
        ],
        fn(message) {
          receive_host_log(host, message, "socket_id", "drops", 200)
          |> should.equal(enabled)
        },
      )
    })
    list.each(
      [
        #(beryl.with_join_rate(config, 1, 1), "Join rate limited"),
        #(beryl.with_message_rate(config, 1, 1), "Message rate limited"),
        #(beryl.with_channel_rate(config, 1, 1), "Channel rate limited"),
        #(
          beryl.with_max_joined_topics_per_socket(config, 1),
          "Join rejected: topic cap exceeded",
        ),
      ],
      fn(pair) {
        use channels <- with_config(pair.0)
        let frames = app_test_helper.connect(channels, "drops")
        app_test_helper.join_ok(channels, frames, "drops", "room:a", "j", "r")
        case pair.1 {
          "Join rate limited" | "Join rejected: topic cap exceeded" -> {
            app_test_helper.join(channels, "drops", "room:b", "j2", "r2")
            let _reply = app_test_helper.recv(frames)
            Nil
          }
          _ -> {
            send_inbound(channels, "room:a", codec.Event("first"))
            send_inbound(channels, "room:a", codec.Event("second"))
          }
        }
        receive_host_log(host, pair.1, "socket_id", "drops", 200)
        |> should.equal(enabled)
      },
    )
  })
}

pub fn repeated_transport_decode_drops_are_debug_and_callback_errors_remain_errors_test() -> Nil {
  use <- unitest.tag("serial")
  use host <- with_host(log.Info)
  use channels <- with_app(beryl.DebugLevel)
  use state <- with_transport(channels, "repeated-drops")
  list.each(list.repeat(Nil, 20), fn(_) {
    let assert server.Continue(_) = server.handle_text_frame(state, "bad-json")
    let assert server.Continue(_) = server.handle_binary_frame(state, <<0>>)
  })
  list.each(
    [
      "Failed to decode wire protocol message",
      "Failed to decode binary wire protocol message",
    ],
    fn(message) {
      receive_host_log(host, message, "logger", "repeated-drops", 0)
      |> should.be_false
    },
  )
  let assert Ok(crashing) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_logging(beryl.logging_config(beryl.ErrorLevel, False)),
      init: fn(_info: socket.ConnectInfo(Nil)) { panic as "callback failure" },
      update: fn(model: Nil, _event) { Next(model, []) },
    )
  use <- with_cleanup(fn() {
    let _ = beryl.stop(crashing)
    Nil
  })
  let assert Ok(owner) = transport.runtime_pid(crashing)
  transport.admit_socket(
    sockets: crashing,
    owner: owner,
    socket_id: "failed-callback",
    send: fn(_) { Ok(Nil) },
    send_binary: fn(_) { Ok(Nil) },
    codec: option.None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.be_error
  receive_host_log(
    host,
    "Socket init crashed; socket not registered",
    "socket_id",
    "failed-callback",
    1000,
  )
  |> should.be_true
}

pub fn shared_text_decode_preview_honors_grapheme_limit_and_opt_in_test() -> Nil {
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()
  let combining = "e" <> string.repeat("\u{301}", 300)
  list.each(
    [
      #("abcdef", 3, "abc"),
      #("abcdef", 0, ""),
      #("abcdef", -1, ""),
      #("👨‍👩‍👧‍👦étail", 2, "👨‍👩‍👧‍👦é"),
      #(combining <> "tail", 1, combining),
    ],
    fn(example) {
      let config =
        beryl.config(wire.phoenix_codec())
        |> beryl.with_logging(
          beryl.logging_config(beryl.DebugLevel, True)
          |> beryl.with_payload_preview_bytes(example.1),
        )
      use channels <- with_config(config)
      use state <- with_transport(channels, "preview-enabled")
      let assert server.Continue(_) = server.handle_text_frame(state, example.0)
      let assert Ok(captured) =
        test_helper.receive_log(
          selector,
          "Failed to decode wire protocol message",
          30,
        )
      dict.get(captured.metadata, "frame_preview")
      |> should.equal(Ok(example.2))
      dict.get(captured.metadata, "payload") |> should.equal(Error(Nil))
      dict.get(captured.metadata, "headers") |> should.equal(Error(Nil))
      dict.get(captured.metadata, "connect_metadata")
      |> should.equal(Error(Nil))
    },
  )
}

pub fn shared_decode_preview_is_absent_without_opt_in_and_for_binary_test() -> Nil {
  use <- unitest.tag("serial")
  use selector <- test_helper.with_capture()
  list.each([False, True], fn(include_payloads) {
    let config =
      beryl.config(wire.phoenix_codec())
      |> beryl.with_logging(beryl.logging_config(
        beryl.DebugLevel,
        include_payloads,
      ))
    use channels <- with_config(config)
    use state <- with_transport(channels, "preview-policy")
    case include_payloads {
      False -> {
        let assert server.Continue(_) =
          server.handle_text_frame(state, "private-text")
        let assert Ok(captured) =
          test_helper.receive_log(
            selector,
            "Failed to decode wire protocol message",
            30,
          )
        dict.get(captured.metadata, "frame_preview")
        |> should.equal(Error(Nil))
        dict.get(captured.metadata, "payload")
        |> should.equal(Error(Nil))
      }
      True -> Nil
    }
    let assert server.Continue(_) =
      server.handle_binary_frame(state, <<"private-binary":utf8>>)
    let assert Ok(captured) =
      test_helper.receive_log(
        selector,
        "Failed to decode binary wire protocol message",
        30,
      )
    dict.get(captured.metadata, "frame_preview") |> should.equal(Error(Nil))
    dict.get(captured.metadata, "payload") |> should.equal(Error(Nil))
  })
}

pub fn preview_opt_in_does_not_bypass_system_or_host_debug_threshold_test() -> Nil {
  use <- unitest.tag("serial")
  list.each(
    [#(log.Info, beryl.DebugLevel), #(log.Debug, beryl.InfoLevel)],
    fn(levels) {
      use host <- with_host(levels.0)
      let config =
        beryl.config(wire.phoenix_codec())
        |> beryl.with_logging(beryl.logging_config(levels.1, True))
      use channels <- with_config(config)
      use state <- with_transport(channels, "disabled-preview")
      let assert server.Continue(_) = server.handle_text_frame(state, "private")
      receive_host_log(
        host,
        "Failed to decode wire protocol message",
        "logger",
        "disabled-preview",
        0,
      )
      |> should.be_false
    },
  )
}
