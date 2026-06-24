//// vsn serializer negotiation tests.
////
//// Exercises the per-connection serializer negotiation added for #44: the
//// Mist transport reads the Phoenix `?vsn=...` query parameter and selects a
//// `codec.Codec` for the lifetime of the connection. `vsn=2.0.0` and
//// connections without a `vsn` use the configured JSON codec; a serializer
//// registered for another `vsn` (here, a binary "MessagePack-style" example)
//// decodes and encodes binary frames for that connection only.
////
//// The example serializer below is a stand-in for a real MessagePack codec.
//// It carries the canonical Phoenix 5-element frame shape
//// `[join_ref, ref, topic, event, payload]` over **binary** frames (encoded
//// here as UTF-8 JSON for test determinism). A production deployment swaps
//// `example_msgpack_serializer()` for a codec backed by an actual MessagePack
//// library (e.g. `tylerbutler/msgpack_gleam`) without any transport changes.

import beryl
import beryl/channel
import beryl/transport/mist as mist_transport
import beryl/wire
import beryl/wire/codec
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleeunit/should
import mist

pub fn main() {
  Nil
}

type WebsocketClient

@external(erlang, "beryl_mist_transport_test_ffi", "connect_websocket")
fn connect_websocket(port: Int, path: String) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "send_text")
fn send_text(
  client: WebsocketClient,
  text: String,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "send_binary")
fn send_binary(
  client: WebsocketClient,
  data: BitArray,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "receive_text")
fn receive_text(client: WebsocketClient, timeout: Int) -> Result(String, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "receive_binary")
fn receive_binary(
  client: WebsocketClient,
  timeout: Int,
) -> Result(BitArray, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "close")
fn close(client: WebsocketClient) -> Nil

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

// --- Example binary "MessagePack-style" serializer -------------------------

/// A test-only stand-in for a MessagePack serializer. It uses the canonical
/// Phoenix 5-element array shape transmitted over binary WebSocket frames.
fn example_msgpack_serializer() -> codec.Codec {
  codec.Codec(
    decode_text: fn(_) {
      Error(codec.InvalidFormat("vsn=3.0.0 expects binary frames"))
    },
    decode_binary: Some(decode_binary_frame),
    encode_reply: fn(join_ref, ref, topic, status, response) {
      to_binary_frame(wire.reply_json(join_ref, ref, topic, status, response))
    },
    encode_push: fn(topic, event, payload) {
      to_binary_frame(wire.push(topic, event, payload))
    },
    encode_heartbeat_reply: fn(ref) {
      to_binary_frame(wire.heartbeat_reply(ref))
    },
  )
}

fn decode_binary_frame(
  data: BitArray,
) -> Result(codec.Inbound, codec.DecodeError) {
  case bit_array.to_string(data) {
    Ok(text) -> wire.decode_message(text)
    Error(_) -> Error(codec.InvalidFormat("invalid UTF-8 binary frame"))
  }
}

fn to_binary_frame(frame: codec.Frame) -> codec.Frame {
  case frame {
    codec.TextFrame(text) -> codec.BinaryFrame(bit_array.from_string(text))
    codec.BinaryFrame(_) -> frame
  }
}

// --- Wire frame helpers ----------------------------------------------------

type Frame {
  Frame(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: dynamic.Dynamic,
  )
}

fn encode_frame(
  join_ref: Option(String),
  ref: Option(String),
  topic: String,
  event: String,
  payload: Json,
) -> String {
  json.to_string(
    json.preprocessed_array([
      option_to_json(join_ref),
      option_to_json(ref),
      json.string(topic),
      json.string(event),
      payload,
    ]),
  )
}

fn option_to_json(value: Option(String)) -> Json {
  case value {
    Some(inner) -> json.string(inner)
    None -> json.null()
  }
}

fn decode_frame(raw: String) -> Result(Frame, Nil) {
  let decoder = {
    use join_ref <- decode.subfield([0], decode.optional(decode.string))
    use ref <- decode.subfield([1], decode.optional(decode.string))
    use topic <- decode.subfield([2], decode.string)
    use event <- decode.subfield([3], decode.string)
    use payload <- decode.subfield([4], decode.dynamic)
    decode.success(Frame(join_ref, ref, topic, event, payload))
  }
  case json.parse(from: raw, using: decoder) {
    Ok(frame) -> Ok(frame)
    Error(_) -> Error(Nil)
  }
}

fn decode_binary_payload(data: BitArray) -> Frame {
  let assert Ok(text) = bit_array.to_string(data)
  let assert Ok(frame) = decode_frame(text)
  frame
}

fn assert_json_field(
  payload: dynamic.Dynamic,
  field: String,
  expected: String,
) {
  let decoder = {
    use value <- decode.field(field, decode.string)
    decode.success(value)
  }
  let assert Ok(actual) = decode.run(payload, decoder)
  actual |> should.equal(expected)
}

fn dynamic_field(payload: dynamic.Dynamic, field: String) -> dynamic.Dynamic {
  let decoder = {
    use value <- decode.field(field, decode.dynamic)
    decode.success(value)
  }
  let assert Ok(value) = decode.run(payload, decoder)
  value
}

// --- Server setup ----------------------------------------------------------

fn echo_channel() -> channel.Channel(Nil, Nil) {
  channel.new(fn(_topic, payload, socket) {
    channel.JoinOk(
      reply: Some(json.object([#("echo", wire.dynamic_to_json(payload))])),
      socket: socket,
    )
  })
  |> channel.with_handle_in(fn(event, payload, socket) {
    case event {
      "ping" ->
        channel.Reply(
          "ping",
          json.object([#("pong", wire.dynamic_to_json(payload))]),
          socket,
        )
      _ -> channel.NoReply(socket)
    }
  })
}

fn start_server(
  channels: beryl.Channels,
  config: mist_transport.TransportConfig(Nil),
) -> #(Int, process.Pid) {
  let port_subject = process.new_subject()
  let handler = fn(request) {
    mist_transport.upgrade(request, channels, config, fn() {
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
  }
  let assert Ok(server) =
    handler
    |> mist.new
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _scheme, _ip) {
      process.send(port_subject, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(port_subject, 1000)
  #(port, server.pid)
}

fn msgpack_config() -> mist_transport.TransportConfig(Nil) {
  mist_transport.default_config("/socket")
  |> mist_transport.with_serializer("3.0.0", example_msgpack_serializer())
}

// --- Tests -----------------------------------------------------------------

pub fn vsn_3_negotiates_binary_serializer_round_trip_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())
  let #(port, server_pid) = start_server(channels, msgpack_config())

  let assert Ok(client) = connect_websocket(port, "/socket?vsn=3.0.0")

  // phx_join over a binary frame with a string-keyed map payload.
  let assert Ok(client) =
    send_binary(
      client,
      bit_array.from_string(encode_frame(
        Some("join-ref"),
        Some("join-1"),
        "room:lobby",
        "phx_join",
        json.object([#("user", json.string("alice"))]),
      )),
    )

  let assert Ok(join_bits) = receive_binary(client, 500)
  let join_reply = decode_binary_payload(join_bits)
  join_reply.join_ref |> should.equal(Some("join-ref"))
  join_reply.ref |> should.equal(Some("join-1"))
  join_reply.topic |> should.equal("room:lobby")
  join_reply.event |> should.equal("phx_reply")
  assert_json_field(join_reply.payload, "status", "ok")
  let response = dynamic_field(join_reply.payload, "response")
  let echoed = dynamic_field(response, "echo")
  assert_json_field(echoed, "user", "alice")

  // Custom event reply over binary.
  let assert Ok(client) =
    send_binary(
      client,
      bit_array.from_string(encode_frame(
        None,
        Some("ev-1"),
        "room:lobby",
        "ping",
        json.object([#("msg", json.string("hi"))]),
      )),
    )
  let assert Ok(event_bits) = receive_binary(client, 500)
  let event_reply = decode_binary_payload(event_bits)
  // null join_ref round-trips as None.
  event_reply.join_ref |> should.equal(None)
  event_reply.ref |> should.equal(Some("ev-1"))
  event_reply.event |> should.equal("phx_reply")
  let pong =
    dynamic_field(dynamic_field(event_reply.payload, "response"), "pong")
  assert_json_field(pong, "msg", "hi")

  // Heartbeat over binary.
  let assert Ok(client) =
    send_binary(
      client,
      bit_array.from_string(encode_frame(
        None,
        Some("hb-1"),
        "phoenix",
        "heartbeat",
        json.object([]),
      )),
    )
  let assert Ok(hb_bits) = receive_binary(client, 500)
  let hb_reply = decode_binary_payload(hb_bits)
  hb_reply.ref |> should.equal(Some("hb-1"))
  hb_reply.event |> should.equal("phx_reply")
  assert_json_field(hb_reply.payload, "status", "ok")

  // Leave over binary.
  let assert Ok(client) =
    send_binary(
      client,
      bit_array.from_string(encode_frame(
        None,
        Some("leave-1"),
        "room:lobby",
        "phx_leave",
        json.object([]),
      )),
    )
  let assert Ok(leave_bits) = receive_binary(client, 500)
  let leave_reply = decode_binary_payload(leave_bits)
  leave_reply.ref |> should.equal(Some("leave-1"))
  leave_reply.event |> should.equal("phx_reply")
  assert_json_field(leave_reply.payload, "status", "ok")

  close(client)
  stop_supervisor(server_pid)
}

pub fn vsn_2_uses_json_text_serializer_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())
  let #(port, server_pid) = start_server(channels, msgpack_config())

  let assert Ok(client) = connect_websocket(port, "/socket?vsn=2.0.0")
  let assert Ok(client) =
    send_text(
      client,
      encode_frame(
        Some("join-ref"),
        Some("join-1"),
        "room:lobby",
        "phx_join",
        json.object([#("user", json.string("bob"))]),
      ),
    )
  let assert Ok(reply_text) = receive_text(client, 500)
  let assert Ok(frame) = decode_frame(reply_text)
  frame.event |> should.equal("phx_reply")
  assert_json_field(frame.payload, "status", "ok")

  close(client)
  stop_supervisor(server_pid)
}

pub fn default_connection_without_vsn_uses_json_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())
  let #(port, server_pid) = start_server(channels, msgpack_config())

  let assert Ok(client) = connect_websocket(port, "/socket")
  let assert Ok(client) =
    send_text(
      client,
      encode_frame(
        None,
        Some("join-1"),
        "room:lobby",
        "phx_join",
        json.object([#("user", json.string("carol"))]),
      ),
    )
  let assert Ok(reply_text) = receive_text(client, 500)
  let assert Ok(frame) = decode_frame(reply_text)
  frame.event |> should.equal("phx_reply")
  assert_json_field(frame.payload, "status", "ok")

  close(client)
  stop_supervisor(server_pid)
}

pub fn mixed_serializers_share_one_server_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())
  let #(port, server_pid) = start_server(channels, msgpack_config())

  // JSON client and binary client connect to the same server concurrently.
  let assert Ok(json_client) = connect_websocket(port, "/socket?vsn=2.0.0")
  let assert Ok(binary_client) = connect_websocket(port, "/socket?vsn=3.0.0")

  let assert Ok(json_client) =
    send_text(
      json_client,
      encode_frame(None, Some("j-1"), "room:lobby", "phx_join", json.object([])),
    )
  let assert Ok(json_reply) = receive_text(json_client, 500)
  let assert Ok(json_frame) = decode_frame(json_reply)
  json_frame.event |> should.equal("phx_reply")

  let assert Ok(binary_client) =
    send_binary(
      binary_client,
      bit_array.from_string(encode_frame(
        None,
        Some("b-1"),
        "room:lobby",
        "phx_join",
        json.object([]),
      )),
    )
  let assert Ok(binary_reply) = receive_binary(binary_client, 500)
  let binary_frame = decode_binary_payload(binary_reply)
  binary_frame.event |> should.equal("phx_reply")
  binary_frame.ref |> should.equal(Some("b-1"))

  close(json_client)
  close(binary_client)
  stop_supervisor(server_pid)
}

pub fn unknown_vsn_falls_back_to_json_by_default_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())
  let #(port, server_pid) = start_server(channels, msgpack_config())

  // vsn=9.9.9 has no registered serializer; default config falls back to JSON.
  let assert Ok(client) = connect_websocket(port, "/socket?vsn=9.9.9")
  let assert Ok(client) =
    send_text(
      client,
      encode_frame(
        None,
        Some("join-1"),
        "room:lobby",
        "phx_join",
        json.object([]),
      ),
    )
  let assert Ok(reply_text) = receive_text(client, 500)
  let assert Ok(frame) = decode_frame(reply_text)
  frame.event |> should.equal("phx_reply")

  close(client)
  stop_supervisor(server_pid)
}

pub fn unknown_vsn_rejected_when_configured_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())
  let config =
    msgpack_config()
    |> mist_transport.with_reject_unknown_vsn(True)
  let #(port, server_pid) = start_server(channels, config)

  // Unknown vsn is rejected with 400 before the WebSocket upgrade completes.
  connect_websocket(port, "/socket?vsn=9.9.9")
  |> should.equal(Error(Nil))

  stop_supervisor(server_pid)
}
