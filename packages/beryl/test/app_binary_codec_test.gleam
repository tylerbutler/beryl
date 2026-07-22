//// Binary-decoder codec parity for app-side dispatch. A codec with a binary
//// decoder routes binary join/event frames through normal dispatch, replies
//// over the binary transport (never text), consumes one message-rate token
//// per binary event, and encodes broadcasts through the binary send path.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Broadcast, Join, Message, Next, ReplyOk}
import beryl/transport
import beryl/wire/codec
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_system() -> beryl.Sockets {
  start_with(beryl.config(binary_test_codec()))
}

fn start_with(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(config, init: fn(_info) { #(Nil, []) }, update: fn(model, ev) {
      case ev {
        Join(_, _, ref) ->
          Next(model, [
            AcceptJoin(ref, Some(json.object([#("joined", json.bool(True))]))),
          ])
        Message(_topic, "ping", _payload, Some(ref)) ->
          Next(model, [ReplyOk(ref, json.object([#("ok", json.bool(True))]))])
        Message(topic, "cast", _payload, _ref) ->
          Next(model, [
            Broadcast(
              topic,
              "announcement",
              json.object([#("body", json.string("hello"))]),
            ),
          ])
        _ -> Next(model, [])
      }
    })
  channels
}

fn connect_binary(
  channels: beryl.Sockets,
  socket_id: String,
) -> #(process.Subject(String), process.Subject(BitArray)) {
  let text = process.new_subject()
  let binary = process.new_subject()
  transport.admit_socket(
    channels: channels,
    owner: transport.connection_owner(channels),
    socket_id: socket_id,
    send: fn(message) {
      process.send(text, message)
      Ok(Nil)
    },
    send_binary: fn(data) {
      process.send(binary, data)
      Ok(Nil)
    },
    codec: None,
    seed: event.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  #(text, binary)
}

fn recv_binary(subject: process.Subject(BitArray)) -> String {
  let assert Ok(bits) = process.receive(subject, 500)
  let assert Ok(text) = bit_array.to_string(bits)
  text
}

fn route_binary(
  channels: beryl.Sockets,
  socket_id: String,
  raw: String,
) -> Nil {
  transport.route_binary(channels, socket_id, bit_array.from_string(raw))
}

pub fn binary_join_and_event_route_and_reply_over_binary_test() {
  let channels = start_system()
  let #(text, binary) = connect_binary(channels, "s1")

  route_binary(channels, "s1", "J|join-ref|join-1|room:lobby|{}")
  recv_binary(binary)
  |> should.equal("R|join-1|room:lobby|ok|{\"joined\":true}")

  route_binary(channels, "s1", "E|event-1|room:lobby|ping|{}")
  recv_binary(binary)
  |> should.equal("R|event-1|room:lobby|ok|{\"ok\":true}")

  // Nothing was ever written to the text transport.
  process.receive(text, 50) |> should.be_error
}

pub fn binary_event_consumes_one_message_rate_token_test() {
  let channels =
    start_with(
      beryl.config(binary_test_codec())
      |> beryl.with_message_rate(per_second: 100, burst: 1),
    )
  let #(_text, binary) = connect_binary(channels, "s1")
  route_binary(channels, "s1", "J|join-ref|join-1|room:lobby|{}")
  let _join_reply = recv_binary(binary)

  // The first event takes the single token and replies; the second is shed.
  route_binary(channels, "s1", "E|event-1|room:lobby|ping|{}")
  recv_binary(binary)
  |> should.equal("R|event-1|room:lobby|ok|{\"ok\":true}")

  route_binary(channels, "s1", "E|event-2|room:lobby|ping|{}")
  process.receive(binary, 100) |> should.be_error
}

pub fn binary_broadcast_uses_binary_send_test() {
  let channels = start_system()
  let #(text, binary) = connect_binary(channels, "s1")
  route_binary(channels, "s1", "J|join-ref|join-1|room:lobby|{}")
  let _join_reply = recv_binary(binary)

  // A Broadcast effect is encoded through the codec's binary push encoder.
  route_binary(channels, "s1", "E|cast-1|room:lobby|cast|{}")
  recv_binary(binary)
  |> should.equal("P|room:lobby|announcement|{\"body\":\"hello\"}")
  process.receive(text, 50) |> should.be_error
}

pub fn undecodable_binary_frame_is_dropped_test() {
  let channels = start_system()
  let #(text, binary) = connect_binary(channels, "s1")
  route_binary(channels, "s1", "J|join-ref|join-1|room:lobby|{}")
  let _join_reply = recv_binary(binary)

  // An undecodable binary frame is dropped by the decoder codec before
  // dispatch: no reply, and nothing is fanned out raw.
  route_binary(channels, "s1", "not-a-valid-frame")
  process.receive(binary, 100) |> should.be_error

  // A following valid event still routes and replies (liveness + ordering).
  route_binary(channels, "s1", "E|event-1|room:lobby|ping|{}")
  recv_binary(binary)
  |> should.equal("R|event-1|room:lobby|ok|{\"ok\":true}")
  process.receive(text, 50) |> should.be_error
}

// ── Custom pipe-delimited binary test codec ─────────────────────────────────

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
