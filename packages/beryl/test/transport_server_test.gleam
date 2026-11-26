import app_test_helper
import beryl
import beryl/snapshot
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import beryl/wire/codec
import gleam/dict
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import test_helper
import unitest

const write_failure_message = "Failed to write outbound WebSocket frame"

pub fn client_ip_default_ignores_spoofed_forwarded_headers_test() -> Nil {
  use sockets <- with_ip_system(
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_connections_per_ip(1),
  )
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.1")
  let request =
    upgrade_request()
    |> request.set_header("x-forwarded-for", "198.51.100.1")
    |> request.set_header("forwarded", "for=198.51.100.1")
  ip_upgrade(
    sockets,
    server.default_config("/socket"),
    request,
    Ok("192.0.2.1"),
  )
  |> should.equal(429)
  ip_upgrade(
    sockets,
    server.default_config("/socket"),
    request,
    Ok("192.0.2.2"),
  )
  |> should.equal(101)
  transport.release_connection_slot(permit)
}

pub fn client_ip_trusted_extractor_controls_concurrency_test() -> Nil {
  use sockets <- with_ip_system(
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_connections_per_ip(1),
  )
  let config =
    server.default_config("/socket")
    |> server.with_client_ip_extractor(trusted_test_proxy)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "198.51.100.1")
  let request =
    upgrade_request() |> request.set_header("x-forwarded-for", "198.51.100.1")
  ip_upgrade(sockets, config, request, Ok("192.0.2.1")) |> should.equal(429)
  ip_upgrade(
    sockets,
    config,
    request.set_header(request, "x-forwarded-for", "198.51.100.2"),
    Ok("192.0.2.1"),
  )
  |> should.equal(101)
  // An untrusted direct peer cannot choose the occupied forwarded bucket.
  ip_upgrade(sockets, config, request, Ok("192.0.2.2")) |> should.equal(101)
  transport.release_connection_slot(permit)
}

pub fn client_ip_extractor_controls_connection_attempt_rate_test() -> Nil {
  use sockets <- with_ip_system(
    beryl.config(wire.phoenix_codec())
    |> beryl.with_connection_rate_per_ip(per_second: 1, burst: 1),
  )
  let config =
    server.default_config("/socket")
    |> server.with_client_ip_extractor(trusted_test_proxy)
  let request =
    upgrade_request() |> request.set_header("x-forwarded-for", "198.51.100.1")
  ip_upgrade(sockets, config, request, Ok("192.0.2.1")) |> should.equal(101)
  ip_upgrade(sockets, config, request, Ok("192.0.2.1")) |> should.equal(429)
  ip_upgrade(
    sockets,
    config,
    request.set_header(request, "x-forwarded-for", "198.51.100.2"),
    Ok("192.0.2.1"),
  )
  |> should.equal(101)
}

pub fn client_ip_failures_reject_before_authentication_and_admission_test() -> Nil {
  list.each(
    [
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(1),
      beryl.config(wire.phoenix_codec())
        |> beryl.with_connection_rate_per_ip(per_second: 1, burst: 1),
    ],
    fn(config) {
      use sockets <- with_ip_system(config)
      let rejecting_auth =
        server.default_config("/socket")
        |> server.with_on_connect(fn(_) { panic as "Authentication ran" })
      list.each([Error(Nil), Ok(""), Ok("unknown")], fn(peer) {
        ip_upgrade(sockets, rejecting_auth, upgrade_request(), peer)
        |> should.equal(403)
      })
      list.each(
        [
          Error(server.ClientIpUnavailable),
          Error(server.ClientIpExtractionFailed),
          Ok(""),
          Ok("unknown"),
        ],
        fn(extracted) {
          let config =
            rejecting_auth
            |> server.with_client_ip_extractor(fn(_, _) { extracted })
          ip_upgrade(sockets, config, upgrade_request(), Ok("192.0.2.1"))
          |> should.equal(403)
        },
      )
      ip_upgrade(
        sockets,
        server.default_config("/socket"),
        upgrade_request(),
        Ok("192.0.2.1"),
      )
      |> should.equal(101)
    },
  )
}

pub fn client_ip_not_required_without_per_ip_controls_test() -> Nil {
  use sockets <- with_ip_system(
    beryl.config(wire.phoenix_codec()) |> beryl.with_max_connections(1),
  )
  let config =
    server.default_config("/socket")
    |> server.with_client_ip_extractor(fn(_, peer) {
      peer |> should.equal(Error(Nil))
      Error(server.ClientIpExtractionFailed)
    })
  ip_upgrade(sockets, config, upgrade_request(), Error(Nil))
  |> should.equal(101)
  ip_upgrade(
    sockets,
    server.default_config("/socket"),
    upgrade_request(),
    Error(Nil),
  )
  |> should.equal(101)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.1")
  ip_upgrade(sockets, config, upgrade_request(), Error(Nil))
  |> should.equal(429)
  transport.release_connection_slot(permit)
}

pub fn client_ip_extractor_runs_once_after_origin_and_version_checks_test() -> Nil {
  use sockets <- with_ip_system(beryl.config(wire.phoenix_codec()))
  let called = process.new_subject()
  let config =
    server.default_config("/socket")
    |> server.with_client_ip_extractor(fn(_, peer) {
      process.send(called, peer)
      Ok("198.51.100.1")
    })
  ip_upgrade(
    sockets,
    config,
    upgrade_request() |> request.set_header("origin", "https://evil.example"),
    Ok("192.0.2.1"),
  )
  |> should.equal(403)
  let assert Ok(version_request) =
    request.to("http://localhost/socket?vsn=9.0.0")
  ip_upgrade(sockets, config, version_request, Ok("192.0.2.1"))
  |> should.equal(403)
  ip_upgrade(
    sockets,
    config,
    upgrade_request() |> request.set_path("/other"),
    Ok("192.0.2.1"),
  )
  |> should.equal(404)
  process.receive(called, 0) |> should.equal(Error(Nil))
  ip_upgrade(sockets, config, upgrade_request(), Ok("192.0.2.1"))
  |> should.equal(101)
  process.receive(called, 0) |> should.equal(Ok(Ok("192.0.2.1")))
  process.receive(called, 0) |> should.equal(Error(Nil))
}

fn upgrade_request() -> request.Request(String) {
  let assert Ok(request) = request.to("http://localhost/socket")
  request
}

fn trusted_test_proxy(
  request: request.Request(String),
  peer: Result(String, Nil),
) -> Result(String, server.ClientIpError) {
  case peer {
    Ok("192.0.2.1") ->
      case request.get_header(request, "x-forwarded-for") {
        Ok("198.51.100.1") -> Ok("198.51.100.1")
        Ok("198.51.100.2") -> Ok("198.51.100.2")
        Ok(_) | Error(Nil) -> Error(server.ClientIpExtractionFailed)
      }
    Ok(ip) -> Ok(ip)
    Error(Nil) -> Error(server.ClientIpUnavailable)
  }
}

fn with_ip_system(
  config: beryl.Config,
  action: fn(beryl.Sockets) -> Nil,
) -> Nil {
  use <- test_helper.with_isolated_caller(5000)
  let assert Ok(sockets) =
    app_test_helper.start_app(
      config,
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  action(sockets)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

fn ip_upgrade(
  sockets: beryl.Sockets,
  config: server.TransportConfig(String),
  request: request.Request(String),
  peer: Result(String, Nil),
) -> Int {
  server.upgrade(
    request: request,
    sockets: sockets,
    config: config,
    telemetry: transport.telemetry(sockets, transport.Custom),
    request_ip: fn(_) { peer },
    reject: fn(status) { response.new(status) },
    accept: fn(_, permit) {
      transport.release_connection_slot(permit)
      response.new(101)
    },
    next: fn() { response.new(404) },
  ).status
}

fn tagged_codec() -> codec.Codec {
  codec.new(
    decode_text: wire.decode_message,
    encode_reply: fn(_join_ref, _ref, topic, _status, payload) {
      Ok(codec.TextFrame(
        "TAGGED-REPLY|" <> topic <> "|" <> json.to_string(payload),
      ))
    },
    encode_push: fn(topic, event, payload) {
      Ok(codec.TextFrame(
        "TAGGED-PUSH|"
        <> topic
        <> "|"
        <> event
        <> "|"
        <> json.to_string(payload),
      ))
    },
    encode_heartbeat_reply: fn(_ref) { Ok(codec.TextFrame("TAGGED-HB")) },
  )
}

pub fn shared_server_preserves_negotiated_socket_codec_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let telemetry = transport.telemetry(sockets, transport.Mist)
  let assert Ok(connection_permit) =
    transport.acquire_connection_slot(sockets, "127.0.0.1")
  let #(state, selector) =
    server.init_connection(
      sockets: sockets,
      seed: socket.ConnectSeed(
        path: "/socket",
        query: [],
        headers: [],
        metadata: [],
      ),
      connection_permit: connection_permit,
      base_selector: process.new_selector(),
      config: server.default_config("/socket"),
      force_close: fn() { Ok(Nil) },
      logger_name: "beryl.transport.server.test",
      telemetry: telemetry,
      codec: Some(tagged_codec()),
    )

  let assert server.Continue(state) =
    server.handle_text_frame(
      state,
      "[null,\"heartbeat-ref\",\"phoenix\",\"heartbeat\",{}]",
    )

  let assert Ok(server.SendText(reply, _)) =
    process.selector_receive(from: selector, within: 500)
  reply |> should.equal("TAGGED-HB")
  server.close_connection(state)
}

pub fn shared_server_closes_when_request_reservation_was_reclaimed_test() -> Nil {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections(max_connections: 1),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let acquired = process.new_subject()
  let _requester =
    process.spawn_unlinked(fn() {
      let assert Ok(permit) =
        transport.acquire_connection_slot(sockets, "127.0.0.1")
      process.send(acquired, permit)
    })
  let assert Ok(connection_permit) = process.receive(acquired, 500)

  test_helper.wait_until(
    fn() {
      case transport.acquire_connection_slot(sockets, "127.0.0.1") {
        Ok(permit) -> {
          transport.release_connection_slot(permit)
          True
        }
        Error(Nil) -> False
      }
    },
    500,
    10,
  )

  let forced_closed = process.new_subject()
  let #(state, selector) =
    server.init_connection(
      sockets: sockets,
      seed: socket.empty_seed(),
      connection_permit: connection_permit,
      base_selector: process.new_selector(),
      config: server.default_config("/socket"),
      force_close: fn() {
        process.send(forced_closed, Nil)
        Ok(Nil)
      },
      logger_name: "beryl.transport.server.test",
      telemetry: transport.telemetry(sockets, transport.Mist),
      codec: None,
    )
  process.selector_receive(selector, 500)
  |> should.equal(Ok(server.Close))
  process.receive(forced_closed, 500) |> should.equal(Ok(Nil))
  let assert Ok(current) = snapshot.get(sockets)
  snapshot.connected_sockets(current) |> should.equal(0)
  server.close_connection(state)
  let assert Ok(Nil) = beryl.stop(sockets)
  Nil
}

pub fn outbound_frame_budget_evicts_before_enqueue_test() -> Nil {
  let assert Ok(config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames: 2, max_bytes: 1024)
  let evicted = process.new_subject()
  let #(state, selector) =
    start_connection(config, fn() {
      process.send(evicted, Nil)
      Ok(Nil)
    })

  send_heartbeat(state, "one")
  send_heartbeat(state, "two")
  send_heartbeat(state, "three")

  let assert Ok(server.SendText(_, _)) =
    process.selector_receive(from: selector, within: 500)
  let assert Ok(server.SendText(_, _)) =
    process.selector_receive(from: selector, within: 500)
  let assert Error(Nil) = process.selector_receive(from: selector, within: 20)
  let assert Ok(Nil) = process.receive(evicted, 500)
  server.close_connection(state)
}

pub fn outbound_byte_budget_releases_after_write_test() -> Nil {
  let assert Ok(config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames: 1, max_bytes: 1024)
  let #(state, selector) = start_connection(config, fn() { Ok(Nil) })

  send_heartbeat(state, "one")
  let assert Ok(server.SendText(_, bytes)) =
    process.selector_receive(from: selector, within: 500)
  let assert server.Continue(state) =
    server.finish_outbound_write(state, bytes, Ok(Nil))

  send_heartbeat(state, "two")
  let assert Ok(server.SendText(_, second_bytes)) =
    process.selector_receive(from: selector, within: 500)
  second_bytes |> should.equal(bytes)
  server.close_connection(state)
}

pub fn outbound_byte_budget_evicts_before_enqueue_test() -> Nil {
  let assert Ok(config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames: 10, max_bytes: 8)
  let evicted = process.new_subject()
  let #(state, selector) =
    start_connection(config, fn() {
      process.send(evicted, Nil)
      Ok(Nil)
    })

  send_heartbeat(state, "too-large")

  let assert Error(Nil) = process.selector_receive(from: selector, within: 20)
  let assert Ok(Nil) = process.receive(evicted, 500)
  server.close_connection(state)
}

pub fn outbound_write_error_cancels_future_enqueues_test() -> Nil {
  let assert Ok(config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames: 10, max_bytes: 1024)
  let evicted = process.new_subject()
  let #(state, selector) =
    start_connection(config, fn() {
      process.send(evicted, Nil)
      Ok(Nil)
    })

  send_heartbeat(state, "write-error")
  let assert Ok(server.SendText(_, bytes)) =
    process.selector_receive(from: selector, within: 500)
  let assert server.Stop =
    server.finish_outbound_write(
      state,
      bytes,
      Error(server.WriteFailed("Timeout")),
    )

  send_heartbeat(state, "after-error")
  let assert Error(Nil) = process.selector_receive(from: selector, within: 20)
  let assert Ok(Nil) = process.receive(evicted, 500)
  server.close_connection(state)
}

pub fn outbound_completion_after_close_is_safe_test() -> Nil {
  let assert Ok(config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames: 1, max_bytes: 1024)
  let #(state, selector) = start_connection(config, fn() { Ok(Nil) })

  send_heartbeat(state, "closing")
  let assert Ok(server.SendText(_, bytes)) =
    process.selector_receive(from: selector, within: 500)
  server.close_connection(state)

  let assert server.Continue(_) =
    server.finish_outbound_write(state, bytes, Ok(Nil))
  Nil
}

pub fn outbound_write_logs_safe_reasons_for_text_and_binary_test() -> Nil {
  use <- unitest.tag("serial")
  use captured <- test_helper.with_capture()
  list.each([False, True], fn(include_payloads) {
    list.each(
      [
        codec.TextFrame("private-outbound-payload"),
        codec.BinaryFrame(<<"private-outbound-payload":utf8>>),
      ],
      fn(frame) {
        list.each(
          [
            "Timeout",
            "Econnreset",
            "Epipe",
            "the client is gone",
            "the client cancelled the stream",
            "the client stopped reading and the write gave up",
            "the socket refused the write, no socket buffer space or memory is left",
          ],
          fn(reason) {
            use state, bytes <- with_outbound_frame(frame, include_payloads)
            let assert server.Stop =
              server.finish_outbound_write(
                state,
                bytes,
                Error(server.WriteFailed(reason)),
              )
            let assert Ok(warning) =
              test_helper.receive_log(captured, write_failure_message, 30)
            dict.get(warning.metadata, "error") |> should.equal(Ok(reason))
            dict.get(warning.metadata, "logger")
            |> should.equal(Ok("beryl.transport.write.test"))
            let assert Ok(socket_id) = dict.get(warning.metadata, "socket_id")
            string.length(socket_id) |> should.equal(32)
            dict.size(warning.metadata) |> should.equal(3)
            let logged =
              warning.message <> string.join(dict.values(warning.metadata), "|")
            list.each(
              [
                "private-outbound-payload",
                "private-connect-metadata",
                "private-header",
                "private-query",
                "192.0.2.123",
              ],
              fn(secret) { string.contains(logged, secret) |> should.be_false },
            )
          },
        )
      },
    )
  })
  test_helper.stop_capture()
  drain_captured_logs(captured)
}

pub fn outbound_success_does_not_log_a_write_failure_test() -> Nil {
  use <- unitest.tag("serial")
  use captured <- test_helper.with_capture()
  list.each(
    [
      codec.TextFrame("private-outbound-payload"),
      codec.BinaryFrame(<<"private-outbound-payload":utf8>>),
    ],
    fn(frame) {
      use state, bytes <- with_outbound_frame(frame, True)
      let assert server.Continue(_) =
        server.finish_outbound_write(state, bytes, Ok(Nil))
      test_helper.receive_log(captured, write_failure_message, 30)
      |> should.equal(Error(Nil))
    },
  )
  test_helper.stop_capture()
  drain_captured_logs(captured)
}

fn drain_captured_logs(
  selector: process.Selector(test_helper.CapturedLog),
) -> Nil {
  case process.selector_receive(selector, 0) {
    Ok(_) -> drain_captured_logs(selector)
    Error(Nil) -> Nil
  }
}

fn with_outbound_frame(
  frame: codec.Frame,
  include_payloads: Bool,
  action: fn(server.ConnectionState, Int) -> Nil,
) -> Nil {
  let codec =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: fn(_, _, _, _, _) { Ok(frame) },
      encode_push: fn(_, _, _) { Ok(frame) },
      encode_heartbeat_reply: fn(_) { Ok(frame) },
    )
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(codec)
        |> beryl.with_logging(beryl.logging_config(
          beryl.DebugLevel,
          include_payloads,
        )),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.123")
  let #(state, selector) =
    server.init_connection(
      sockets: sockets,
      seed: socket.ConnectSeed(
        path: "/socket",
        query: [#("token", "private-query")],
        headers: [#("authorization", "private-header")],
        metadata: [#("token", "private-connect-metadata")],
      ),
      connection_permit: permit,
      base_selector: process.new_selector(),
      config: server.default_config("/socket"),
      force_close: fn() { Ok(Nil) },
      logger_name: "beryl.transport.write.test",
      telemetry: transport.telemetry(sockets, transport.Mist),
      codec: None,
    )
  send_heartbeat(state, "write")
  let assert Ok(request) = process.selector_receive(selector, 500)
  let bytes = case request {
    server.SendText(_, bytes) | server.SendBinary(_, bytes) -> bytes
    server.Close -> panic as "Expected an outbound frame"
  }
  action(state, bytes)
  server.close_connection(state)
  let assert Ok(Nil) = beryl.stop(sockets)
  process.selector_receive(selector, 500) |> should.equal(Ok(server.Close))
  Nil
}

pub fn outbound_config_rejects_non_positive_limits_test() -> Nil {
  server.default_config("/socket")
  |> server.with_outbound_limits(max_frames: 0, max_bytes: 1)
  |> should.equal(Error(server.InvalidMaxOutboundFrames))

  server.default_config("/socket")
  |> server.with_outbound_limits(max_frames: 1, max_bytes: 0)
  |> should.equal(Error(server.InvalidMaxOutboundBytes))

  server.default_config("/socket")
  |> server.with_outbound_limits(max_frames: 8_388_608, max_bytes: 1)
  |> should.equal(Error(server.MaxOutboundFramesTooLarge))

  server.default_config("/socket")
  |> server.with_outbound_limits(max_frames: 1, max_bytes: 1_099_511_627_776)
  |> should.equal(Error(server.MaxOutboundBytesTooLarge))
}

fn start_connection(
  config: server.TransportConfig(body),
  force_close: fn() -> Result(Nil, server.ForceCloseError),
) -> #(server.ConnectionState, process.Selector(server.SendRequest)) {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let assert Ok(connection_permit) =
    transport.acquire_connection_slot(sockets, "127.0.0.1")
  server.init_connection(
    sockets: sockets,
    seed: socket.ConnectSeed(
      path: "/socket",
      query: [],
      headers: [],
      metadata: [],
    ),
    connection_permit: connection_permit,
    base_selector: process.new_selector(),
    config: config,
    force_close: force_close,
    logger_name: "beryl.transport.server.test",
    telemetry: transport.telemetry(sockets, transport.Mist),
    codec: Some(tagged_codec()),
  )
}

fn send_heartbeat(state: server.ConnectionState, message_ref: String) -> Nil {
  let assert server.Continue(_) =
    server.handle_text_frame(
      state,
      "[null,\"" <> message_ref <> "\",\"phoenix\",\"heartbeat\",{}]",
    )
  Nil
}
