//// A custom binary codec driven through the app runtime: decoded binary
//// frames become `Join`/`Message` events, replies and broadcasts are
//// encoded back through the codec's binary frames, and codecs without a
//// binary decoder fan raw frames out as `Binary` events.

import app_test_helpers as h
import beryl
import beryl/socket.{AcceptJoin, Binary, Join, Message, Next, ReplyOk}
import beryl/transport
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
  codec.new(
    decode_text: fn(_) { Error(codec.InvalidFormat("text unsupported")) },
    encode_reply: encode_reply,
    encode_push: encode_push,
    encode_heartbeat_reply: encode_heartbeat_reply,
  )
  |> codec.with_binary_decoder(decode_binary_frame)
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
      Ok(codec.inbound(
        join_ref: Some(join_ref),
        ref: Some(ref),
        topic: topic,
        kind: codec.Join,
        payload: payload,
      ))
    }
    ["L", ref, topic] ->
      Ok(codec.inbound(
        join_ref: None,
        ref: Some(ref),
        topic: topic,
        kind: codec.Leave,
        payload: dynamic_nil(),
      ))
    ["H", ref] ->
      Ok(codec.inbound(
        join_ref: None,
        ref: Some(ref),
        topic: "phoenix",
        kind: codec.Heartbeat,
        payload: dynamic_nil(),
      ))
    ["E", ref, topic, event, payload_json] -> {
      use payload <- result_try(decode_payload(payload_json))
      Ok(codec.inbound(
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

/// Connect a socket capturing both text and binary outbound frames.
fn connect_binary(
  channels: beryl.Sockets,
  socket_id: String,
) -> #(process.Subject(String), process.Subject(BitArray)) {
  let sent_text = process.new_subject()
  let sent_binary = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(channels)
  transport.admit_socket(
    sockets: channels,
    owner: owner,
    socket_id: socket_id,
    send: fn(text) {
      process.send(sent_text, text)
      Ok(Nil)
    },
    send_binary: fn(data) {
      process.send(sent_binary, data)
      Ok(Nil)
    },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  #(sent_text, sent_binary)
}

pub fn binary_codec_routes_join_message_and_reply_over_binary_test() {
  let seen_payload = process.new_subject()
  let assert Ok(channels) =
    h.start_app(
      beryl.config(binary_test_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_topic, payload, ref) -> {
            let user_decoder = {
              use user <- decode.field("user", decode.string)
              decode.success(user)
            }
            let assert Ok(user) = decode.run(payload, user_decoder)
            process.send(seen_payload, user)
            Next(model, [
              AcceptJoin(ref, Some(json.object([#("joined", json.bool(True))]))),
            ])
          }
          Message(_topic, event_name, payload, Some(ref)) -> {
            let body_decoder = {
              use body <- decode.field("body", decode.string)
              decode.success(body)
            }
            let assert Ok(body) = decode.run(payload, body_decoder)
            process.send(seen_payload, event_name <> ":" <> body)
            Next(model, [ReplyOk(ref, json.object([#("ok", json.bool(True))]))])
          }
          _ -> Next(model, [])
        }
      },
    )

  let #(sent_text, sent_binary) = connect_binary(channels, "socket-1")

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("J|join-ref|join-1|room:lobby|{\"user\":\"alice\"}"),
  )

  process.receive(seen_payload, 500) |> should.equal(Ok("alice"))
  let assert Ok(join_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(join_reply_bits)
  |> should.equal(Ok("R|join-1|room:lobby|ok|{\"joined\":true}"))

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("E|event-1|room:lobby|ping|{\"body\":\"hi\"}"),
  )

  process.receive(seen_payload, 500) |> should.equal(Ok("ping:hi"))
  let assert Ok(event_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(event_reply_bits)
  |> should.equal(Ok("R|event-1|room:lobby|ok|{\"ok\":true}"))

  process.receive(sent_text, 50) |> should.be_error

  beryl.stop(channels)
}

pub fn binary_codec_event_consumes_one_message_rate_token_test() {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(binary_test_codec())
        |> beryl.with_message_rate(per_second: 100, burst: 2),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(_topic, event_name, _payload, Some(ref)) -> {
            let _ = event_name
            Next(model, [ReplyOk(ref, json.object([#("ok", json.bool(True))]))])
          }
          _ -> Next(model, [])
        }
      },
    )

  let #(_sent_text, sent_binary) = connect_binary(channels, "socket-1")

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("J|join-ref|join-1|room:lobby|{}"),
  )
  let assert Ok(_join_reply_bits) = process.receive(sent_binary, 500)

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("E|event-1|room:lobby|ping|{}"),
  )
  let assert Ok(first_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(first_reply_bits)
  |> should.equal(Ok("R|event-1|room:lobby|ok|{\"ok\":true}"))

  transport.route_binary(
    channels,
    "socket-1",
    bit_array.from_string("E|event-2|room:lobby|ping|{}"),
  )
  let assert Ok(second_reply_bits) = process.receive(sent_binary, 500)
  bit_array.to_string(second_reply_bits)
  |> should.equal(Ok("R|event-2|room:lobby|ok|{\"ok\":true}"))

  beryl.stop(channels)
}

pub fn binary_codec_broadcast_uses_binary_send_test() {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(binary_test_codec()),
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          _ -> Next(model, [])
        }
      },
    )

  let #(sent_text, sent_binary) = connect_binary(channels, "socket-1")

  transport.route_binary(
    channels,
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

  beryl.stop(channels)
}

pub fn codec_without_binary_decoder_delivers_raw_binary_events_test() {
  let seen_binary = process.new_subject()
  // A text-only codec (no binary decoder): raw binary frames fan out to the
  // app as `Binary` events. The Phoenix codec now ships its own binary
  // decoder, so this path applies only to custom codecs that opt out.
  let text_only =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: wire.reply_json,
      encode_push: wire.push,
      encode_heartbeat_reply: wire.heartbeat_reply,
    )
  let assert Ok(channels) =
    h.start_app(
      beryl.config(text_only),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Binary(_topic, data) -> {
            process.send(seen_binary, data)
            Next(model, [])
          }
          _ -> Next(model, [])
        }
      },
    )

  let #(sent_text, _sent_binary) = connect_binary(channels, "socket-1")

  let assert Ok(msg) =
    codec.decode_text(transport.active_codec(channels))(
      "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
    )
  transport.route_decoded(channels, "socket-1", msg)
  let assert Ok(_join_reply) = process.receive(sent_text, 500)

  transport.route_binary(channels, "socket-1", bit_array.from_string("raw"))

  let assert Ok(raw_bits) = process.receive(seen_binary, 500)
  bit_array.to_string(raw_bits) |> should.equal(Ok("raw"))

  beryl.stop(channels)
}
