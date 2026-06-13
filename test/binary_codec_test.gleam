import beryl
import beryl/channel
import beryl/coordinator
import beryl/wire
import beryl/wire/codec
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should

pub fn main() {
  Nil
}

fn binary_test_codec() -> codec.Codec {
  codec.Codec(
    decode_text: fn(_) { Error(codec.InvalidFormat("text unsupported")) },
    decode_binary: Some(decode_binary_frame),
    encode_reply: encode_reply,
    encode_push: encode_push,
    encode_heartbeat_reply: encode_heartbeat_reply,
  )
}

fn decode_binary_frame(
  data: BitArray,
) -> Result(codec.Inbound, codec.DecodeError) {
  case bit_array.to_string(data) {
    Ok(raw) -> decode_binary_text(raw)
    Error(_) -> Error(codec.InvalidFormat("Expected UTF-8 binary test frame"))
  }
}

fn decode_binary_text(raw: String) -> Result(codec.Inbound, codec.DecodeError) {
  case string.split(raw, "|") {
    ["J", join_ref, ref, topic, payload_json] -> {
      use payload <- result_try(decode_payload(payload_json))
      Ok(codec.Inbound(
        join_ref: Some(join_ref),
        ref: Some(ref),
        topic: topic,
        kind: codec.Join,
        payload: payload,
      ))
    }
    ["L", ref, topic] ->
      Ok(codec.Inbound(
        join_ref: None,
        ref: Some(ref),
        topic: topic,
        kind: codec.Leave,
        payload: dynamic_nil(),
      ))
    ["H", ref] ->
      Ok(codec.Inbound(
        join_ref: None,
        ref: Some(ref),
        topic: "phoenix",
        kind: codec.Heartbeat,
        payload: dynamic_nil(),
      ))
    ["E", ref, topic, event, payload_json] -> {
      use payload <- result_try(decode_payload(payload_json))
      Ok(codec.Inbound(
        join_ref: None,
        ref: Some(ref),
        topic: topic,
        kind: codec.Event(event),
        payload: payload,
      ))
    }
    _ -> Error(codec.InvalidFormat("Unknown binary test frame"))
  }
}

fn decode_payload(payload_json: String) -> Result(Dynamic, codec.DecodeError) {
  case json.parse(from: payload_json, using: decode.dynamic) {
    Ok(payload) -> Ok(payload)
    Error(_) -> Error(codec.InvalidJson("Invalid payload JSON"))
  }
}

fn result_try(
  result: Result(a, codec.DecodeError),
  next: fn(a) -> Result(b, codec.DecodeError),
) -> Result(b, codec.DecodeError) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn dynamic_nil() -> Dynamic {
  json.parse(from: "{}", using: decode.dynamic)
  |> result_to_dynamic
}

fn result_to_dynamic(result: Result(Dynamic, a)) -> Dynamic {
  let assert Ok(value) = result
  value
}

fn encode_reply(
  _join_ref: Option(String),
  ref: Option(String),
  topic: String,
  status: codec.ReplyStatus,
  response: json.Json,
) -> codec.Frame {
  let status_string = case status {
    codec.StatusOk -> "ok"
    codec.StatusError -> "error"
  }

  {
    "R|"
    <> ref_to_string(ref)
    <> "|"
    <> topic
    <> "|"
    <> status_string
    <> "|"
    <> json.to_string(response)
  }
  |> bit_array.from_string
  |> codec.BinaryFrame
}

fn encode_push(
  topic: String,
  event: String,
  payload: json.Json,
) -> codec.Frame {
  { "P|" <> topic <> "|" <> event <> "|" <> json.to_string(payload) }
  |> bit_array.from_string
  |> codec.BinaryFrame
}

fn encode_heartbeat_reply(ref: Option(String)) -> codec.Frame {
  encode_reply(None, ref, "phoenix", codec.StatusOk, json.object([]))
}

fn ref_to_string(ref: Option(String)) -> String {
  case ref {
    Some(value) -> value
    None -> "null"
  }
}

pub fn binary_codec_routes_join_message_and_reply_over_binary_test() {
  let sent_text = process.new_subject()
  let sent_binary = process.new_subject()
  let assert Ok(channels) = beryl.start(beryl.config(binary_test_codec()))

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "socket-1",
      fn(text) {
        process.send(sent_text, text)
        Ok(Nil)
      },
      fn(data) {
        process.send(sent_binary, data)
        Ok(Nil)
      },
      None,
    ),
  )

  let seen_payload = process.new_subject()
  let handler =
    channel.new(fn(_topic, payload, socket) {
      let user_decoder = {
        use user <- decode.field("user", decode.string)
        decode.success(user)
      }
      let assert Ok(user) = channel.decode_payload(payload, user_decoder)
      process.send(seen_payload, user)
      channel.JoinOk(
        reply: Some(json.object([#("joined", json.bool(True))])),
        socket: socket,
      )
    })
    |> channel.with_handle_in(fn(event, payload, socket) {
      let body_decoder = {
        use body <- decode.field("body", decode.string)
        decode.success(body)
      }
      let assert Ok(body) = channel.decode_payload(payload, body_decoder)
      process.send(seen_payload, event <> ":" <> body)
      channel.Reply(event, json.object([#("ok", json.bool(True))]), socket)
    })

  beryl.register(channels, "room:*", handler) |> should.equal(Ok(Nil))

  coordinator.route_binary(
    channels.coordinator,
    "socket-1",
    bit_array.from_string("J|join-ref|join-1|room:lobby|{\"user\":\"alice\"}"),
  )

  process.receive(seen_payload, 500) |> should.equal(Ok("alice"))
  let assert Ok(join_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(join_reply_bits)
  |> should.equal(Ok("R|join-1|room:lobby|ok|{\"joined\":true}"))

  coordinator.route_binary(
    channels.coordinator,
    "socket-1",
    bit_array.from_string("E|event-1|room:lobby|ping|{\"body\":\"hi\"}"),
  )

  process.receive(seen_payload, 500) |> should.equal(Ok("ping:hi"))
  let assert Ok(event_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(event_reply_bits)
  |> should.equal(Ok("R|event-1|room:lobby|ok|{\"ok\":true}"))

  process.receive(sent_text, 50) |> should.be_error
}

pub fn binary_codec_event_consumes_one_message_rate_token_test() {
  let sent_binary = process.new_subject()
  let config =
    beryl.config(binary_test_codec())
    |> beryl.with_message_rate(per_second: 100, burst: 2)
  let assert Ok(channels) = beryl.start(config)

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "socket-1",
      fn(_) { Ok(Nil) },
      fn(data) {
        process.send(sent_binary, data)
        Ok(Nil)
      },
      None,
    ),
  )

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
    |> channel.with_handle_in(fn(event, _payload, socket) {
      channel.Reply(event, json.object([#("ok", json.bool(True))]), socket)
    })

  beryl.register(channels, "room:*", handler) |> should.equal(Ok(Nil))

  coordinator.route_binary(
    channels.coordinator,
    "socket-1",
    bit_array.from_string("J|join-ref|join-1|room:lobby|{}"),
  )
  let assert Ok(_join_reply_bits) = process.receive(sent_binary, 500)

  coordinator.route_binary(
    channels.coordinator,
    "socket-1",
    bit_array.from_string("E|event-1|room:lobby|ping|{}"),
  )
  let assert Ok(first_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(first_reply_bits)
  |> should.equal(Ok("R|event-1|room:lobby|ok|{\"ok\":true}"))

  coordinator.route_binary(
    channels.coordinator,
    "socket-1",
    bit_array.from_string("E|event-2|room:lobby|ping|{}"),
  )
  let assert Ok(second_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(second_reply_bits)
  |> should.equal(Ok("R|event-2|room:lobby|ok|{\"ok\":true}"))
}

pub fn binary_codec_broadcast_uses_binary_send_test() {
  let sent_text = process.new_subject()
  let sent_binary = process.new_subject()
  let assert Ok(channels) = beryl.start(beryl.config(binary_test_codec()))

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "socket-1",
      fn(text) {
        process.send(sent_text, text)
        Ok(Nil)
      },
      fn(data) {
        process.send(sent_binary, data)
        Ok(Nil)
      },
      None,
    ),
  )

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })

  beryl.register(channels, "room:*", handler) |> should.equal(Ok(Nil))

  coordinator.route_binary(
    channels.coordinator,
    "socket-1",
    bit_array.from_string("J|join-ref|join-1|room:lobby|{}"),
  )
  let assert Ok(_join_reply) = process.receive(sent_binary, 500)

  beryl.broadcast(
    channels,
    "room:lobby",
    "announcement",
    json.object([#("body", json.string("hello"))]),
  )

  let assert Ok(broadcast_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(broadcast_bits)
  |> should.equal(Ok("P|room:lobby|announcement|{\"body\":\"hello\"}"))
  process.receive(sent_text, 50) |> should.be_error
}

pub fn phoenix_codec_without_binary_decoder_preserves_raw_binary_handler_test() {
  let sent_text = process.new_subject()
  let seen_binary = process.new_subject()
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "socket-1",
      fn(text) {
        process.send(sent_text, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      None,
    ),
  )

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
    |> channel.with_handle_binary(fn(data, socket) {
      process.send(seen_binary, data)
      channel.NoReply(socket)
    })

  beryl.register(channels, "room:*", handler) |> should.equal(Ok(Nil))

  coordinator.route_message(
    channels.coordinator,
    "socket-1",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_join_reply) = process.receive(sent_text, 500)

  coordinator.route_binary(
    channels.coordinator,
    "socket-1",
    bit_array.from_string("raw"),
  )

  let assert Ok(raw_bits) = process.receive(seen_binary, 500)
  bit_array.to_string(raw_bits) |> should.equal(Ok("raw"))
}
