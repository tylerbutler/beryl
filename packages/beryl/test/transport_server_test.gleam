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
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import test_helper
import unitest

const write_failure_message = "Failed to write outbound WebSocket frame"

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
      encode_reply: fn(_, _, _, _, _) { frame },
      encode_push: fn(_, _, _) { frame },
      encode_heartbeat_reply: fn(_) { frame },
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
