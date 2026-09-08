import app_test_helper
import beryl
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
      logger_name: "beryl.transport.server.test",
      telemetry: telemetry,
      codec: Some(tagged_codec()),
    )

  let assert server.Continue(state) =
    server.handle_text_frame(
      state,
      "[null,\"heartbeat-ref\",\"phoenix\",\"heartbeat\",{}]",
    )

  let assert Ok(server.SendText(reply)) =
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

  let #(state, selector) =
    server.init_connection(
      sockets: sockets,
      seed: socket.empty_seed(),
      connection_permit: connection_permit,
      base_selector: process.new_selector(),
      logger_name: "beryl.transport.server.test",
      telemetry: transport.telemetry(sockets, transport.Mist),
      codec: None,
    )
  process.selector_receive(selector, 500)
  |> should.equal(Ok(server.Close))
  server.close_connection(state)
  let assert Ok(Nil) = beryl.stop(sockets)
  Nil
}
