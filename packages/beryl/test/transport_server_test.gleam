import app_test_helper
import beryl
import beryl/snapshot
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import test_helper

fn tagged_codec() -> codec.Codec {
  codec.new(
    decode_text: wire.decode_message,
    encode_reply: fn(_join_ref, _ref, topic, _status, payload) {
      codec.TextFrame(
        "TAGGED-REPLY|" <> topic <> "|" <> json.to_string(payload),
      )
    },
    encode_push: fn(topic, event, payload) {
      codec.TextFrame(
        "TAGGED-PUSH|"
        <> topic
        <> "|"
        <> event
        <> "|"
        <> json.to_string(payload),
      )
    },
    encode_heartbeat_reply: fn(_ref) { codec.TextFrame("TAGGED-HB") },
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
    |> server.with_outbound_limits(max_frames: 10, max_bytes: 64)
  let #(state, selector) = start_connection(config, fn() { Ok(Nil) })

  send_heartbeat(state, "one")
  let assert Ok(server.SendText(_, bytes)) =
    process.selector_receive(from: selector, within: 500)
  let assert server.Continue(state) =
    server.finish_outbound_write(state, bytes, True)

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
  let assert server.Stop = server.finish_outbound_write(state, bytes, False)

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
    server.finish_outbound_write(state, bytes, True)
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
