import app_test_helper
import beryl
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleam/json
import gleam/option.{Some}
import gleeunit/should

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
