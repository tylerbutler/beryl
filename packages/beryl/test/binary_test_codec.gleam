//// Shared pipe-delimited binary test codec used by the binary-codec suites
//// (`binary_codec_test`, `app_binary_codec_test`). Frames:
////
////   J|join_ref|ref|topic|payload_json   join
////   L|ref|topic                         leave
////   H|ref                               heartbeat
////   E|ref|topic|event|payload_json      event
////
//// Replies encode as `R|ref|topic|status|response_json`, pushes as
//// `P|topic|event|payload_json`.

import beryl/wire/codec
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn new() -> codec.Codec {
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
      use payload <- result.try(decode_payload(payload_json))
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
      use payload <- result.try(decode_payload(payload_json))
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

fn dynamic_nil() -> Dynamic {
  let assert Ok(value) = json.parse(from: "{}", using: decode.dynamic)
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
    <> option.unwrap(ref, "null")
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
