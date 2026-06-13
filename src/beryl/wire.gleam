//// Phoenix Wire Protocol — encoding/decoding helpers and the canonical
//// `phoenix_codec()` for `beryl/wire/codec`.
////
//// Phoenix uses a JSON array format: `[join_ref, ref, topic, event, payload]`.
//// This module parses and emits that format, and exposes a `Codec` value
//// that plugs the Phoenix framing into the coordinator.
////
//// To use Phoenix framing (the historical default) construct beryl with:
////
//// ```gleam
//// beryl.config(wire.phoenix_codec())
//// ```

import beryl/wire/codec.{
  type Codec, type DecodeError, type Frame, type Inbound, type InboundKind,
  type ReplyStatus, Codec, Event, Heartbeat, Inbound, InvalidFormat, InvalidJson,
  Join, Leave, StatusError, StatusOk, TextFrame,
}
import envoy
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import roost/frame as roost_frame

const expected_array_message = "Expected array of 5 elements [join_ref, ref, topic, event, payload]"

const phoenix_codec_env = "BERYL_PHOENIX_CODEC"

type PhoenixCodecImplementation {
  NativePhoenixCodec
  RoostPhoenixCodec
}

fn phoenix_codec_implementation() -> PhoenixCodecImplementation {
  case envoy.get(phoenix_codec_env) {
    Ok("roost") -> RoostPhoenixCodec
    _ -> NativePhoenixCodec
  }
}

/// The canonical Phoenix wire codec. Pass to `beryl.config/1`.
///
/// By default this uses Beryl's native Phoenix implementation. Set
/// `BERYL_PHOENIX_CODEC=roost` before constructing the codec to opt into the
/// Roost-backed implementation.
pub fn phoenix_codec() -> Codec {
  case phoenix_codec_implementation() {
    NativePhoenixCodec -> native_phoenix_codec()
    RoostPhoenixCodec -> roost_phoenix_codec()
  }
}

fn native_phoenix_codec() -> Codec {
  Codec(
    decode_text: decode_message,
    decode_binary: None,
    encode_reply: reply_json,
    encode_push: push,
    encode_heartbeat_reply: heartbeat_reply,
  )
}

fn roost_phoenix_codec() -> Codec {
  Codec(
    decode_text: decode_message_with_roost,
    decode_binary: None,
    encode_reply: reply_json_with_roost,
    encode_push: push_with_roost,
    encode_heartbeat_reply: heartbeat_reply_with_roost,
  )
}

fn decode_message_with_roost(
  json_string: String,
) -> Result(Inbound, DecodeError) {
  case roost_frame.decode(json_string) {
    Ok(frame) ->
      Ok(Inbound(
        join_ref: frame.join_ref,
        ref: frame.ref,
        topic: frame.topic,
        kind: classify_phoenix_event_with_roost(frame.event),
        payload: frame.payload,
      ))
    Error(roost_frame.InvalidJson(reason)) -> Error(InvalidJson(reason))
    Error(roost_frame.InvalidFormat(reason)) -> Error(InvalidFormat(reason))
  }
}

fn classify_phoenix_event_with_roost(event: String) -> InboundKind {
  case event {
    event if event == roost_frame.join_event -> Join
    event if event == roost_frame.leave_event -> Leave
    event if event == roost_frame.heartbeat_event -> Heartbeat
    other -> Event(other)
  }
}

fn reply_status_to_roost(status: ReplyStatus) -> roost_frame.ReplyStatus {
  case status {
    StatusOk -> roost_frame.StatusOk
    StatusError -> roost_frame.StatusError
  }
}

fn reply_status_string(status: ReplyStatus) -> String {
  case status {
    StatusOk -> "ok"
    StatusError -> "error"
  }
}

fn push_with_roost(topic: String, event: String, payload: json.Json) -> Frame {
  TextFrame(roost_frame.encode(
    join_ref: None,
    ref: None,
    topic: topic,
    event: event,
    payload: payload,
  ))
}

fn reply_json_with_roost(
  join_ref: Option(String),
  ref: Option(String),
  topic: String,
  status: ReplyStatus,
  response: json.Json,
) -> Frame {
  case ref {
    Some(ref) ->
      TextFrame(roost_frame.encode_reply(
        join_ref: join_ref,
        ref: ref,
        topic: topic,
        status: reply_status_to_roost(status),
        response: response,
      ))
    None ->
      TextFrame(roost_frame.encode(
        join_ref: join_ref,
        ref: None,
        topic: topic,
        event: roost_frame.reply_event,
        payload: json.object([
          #("status", json.string(reply_status_string(status))),
          #("response", response),
        ]),
      ))
  }
}

fn heartbeat_reply_with_roost(ref: Option(String)) -> Frame {
  reply_json_with_roost(
    None,
    ref,
    roost_frame.heartbeat_topic,
    StatusOk,
    json.object([]),
  )
}

/// Parse a JSON string into an `Inbound`.
///
/// Expected format: `[join_ref, ref, topic, event, payload]` where
/// `join_ref` and `ref` may be `null`.
pub fn decode_message(json_string: String) -> Result(Inbound, DecodeError) {
  case json.parse(from: json_string, using: decode.dynamic) {
    Ok(value) -> decode_inbound_value(value)
    Error(json.UnexpectedEndOfInput) ->
      Error(InvalidJson("Unexpected end of input"))
    Error(json.UnexpectedByte(byte)) ->
      Error(InvalidJson("Unexpected byte: " <> byte))
    Error(json.UnexpectedSequence(seq)) ->
      Error(InvalidJson("Unexpected sequence: " <> seq))
    Error(json.UnableToDecode(_)) ->
      Error(InvalidFormat(expected_array_message))
  }
}

fn decode_inbound_value(value: Dynamic) -> Result(Inbound, DecodeError) {
  case decode.run(value, decode.list(decode.dynamic)) {
    Ok(items) ->
      case list.length(items) {
        5 -> decode_inbound_fields(value)
        _ -> Error(InvalidFormat(expected_array_message))
      }
    Error(_) -> Error(InvalidFormat(expected_array_message))
  }
}

fn decode_inbound_fields(value: Dynamic) -> Result(Inbound, DecodeError) {
  let wire_decoder = {
    use join_ref <- decode.subfield([0], decode.optional(decode.string))
    use ref <- decode.subfield([1], decode.optional(decode.string))
    use topic <- decode.subfield([2], decode.string)
    use event <- decode.subfield([3], decode.string)
    use payload <- decode.subfield([4], decode.dynamic)
    decode.success(Inbound(
      join_ref: join_ref,
      ref: ref,
      topic: topic,
      kind: classify_phoenix_event(event),
      payload: payload,
    ))
  }

  case decode.run(value, wire_decoder) {
    Ok(msg) -> Ok(msg)
    Error(_) -> Error(InvalidFormat(expected_array_message))
  }
}

/// Encode an `Inbound` back to a Phoenix wire JSON string.
pub fn encode(msg: Inbound) -> String {
  let join_ref_json = option_to_json(msg.join_ref)
  let ref_json = option_to_json(msg.ref)
  let payload_json = dynamic_to_json(msg.payload)
  let event = phoenix_event_name(msg.kind)

  json.to_string(
    json.preprocessed_array([
      join_ref_json,
      ref_json,
      json.string(msg.topic),
      json.string(event),
      payload_json,
    ]),
  )
}

fn classify_phoenix_event(event: String) -> InboundKind {
  case event {
    "phx_join" -> Join
    "phx_leave" -> Leave
    "heartbeat" -> Heartbeat
    other -> Event(other)
  }
}

fn phoenix_event_name(kind: InboundKind) -> String {
  case kind {
    Join -> "phx_join"
    Leave -> "phx_leave"
    Heartbeat -> "heartbeat"
    Event(event) -> event
  }
}

/// Convert a `Dynamic` (decoded from JSON) back into `json.Json`.
pub fn dynamic_to_json(value: Dynamic) -> json.Json {
  decode.run(value, decode.string)
  |> result.map(json.string)
  |> result.lazy_unwrap(fn() { try_decode_int(value) })
}

fn try_decode_int(value: Dynamic) -> json.Json {
  decode.run(value, decode.int)
  |> result.map(json.int)
  |> result.lazy_unwrap(fn() { try_decode_float(value) })
}

fn try_decode_float(value: Dynamic) -> json.Json {
  decode.run(value, decode.float)
  |> result.map(json.float)
  |> result.lazy_unwrap(fn() { try_decode_bool(value) })
}

fn try_decode_bool(value: Dynamic) -> json.Json {
  decode.run(value, decode.bool)
  |> result.map(json.bool)
  |> result.lazy_unwrap(fn() { try_decode_complex(value) })
}

fn try_decode_complex(value: Dynamic) -> json.Json {
  case dynamic.classify(value) {
    "Nil" -> json.null()
    "List" -> decode_list_to_json(value)
    _ -> decode_object_to_json(value)
  }
}

fn decode_list_to_json(value: Dynamic) -> json.Json {
  decode.run(value, decode.list(decode.dynamic))
  |> result.map(fn(items) {
    json.preprocessed_array(list.map(items, dynamic_to_json))
  })
  |> result.unwrap(json.null())
}

fn decode_object_to_json(value: Dynamic) -> json.Json {
  let dict_decoder = decode.dict(decode.string, decode.dynamic)
  decode.run(value, dict_decoder)
  |> result.map(fn(decoded) {
    decoded
    |> dict.to_list()
    |> list.map(fn(pair) {
      let #(k, v) = pair
      #(k, dynamic_to_json(v))
    })
    |> json.object()
  })
  |> result.unwrap(json.null())
}

/// Create a Phoenix `phx_reply` JSON string.
pub fn reply_json(
  join_ref: Option(String),
  ref: Option(String),
  topic: String,
  status: ReplyStatus,
  response: json.Json,
) -> Frame {
  let status_string = case status {
    StatusOk -> "ok"
    StatusError -> "error"
  }

  let payload =
    json.object([
      #("status", json.string(status_string)),
      #("response", response),
    ])

  TextFrame(
    json.to_string(
      json.preprocessed_array([
        option_to_json(join_ref),
        option_to_json(ref),
        json.string(topic),
        json.string("phx_reply"),
        payload,
      ]),
    ),
  )
}

/// Create a server-initiated push message.
pub fn push(topic: String, event: String, payload: json.Json) -> Frame {
  TextFrame(
    json.to_string(
      json.preprocessed_array([
        json.null(),
        json.null(),
        json.string(topic),
        json.string(event),
        payload,
      ]),
    ),
  )
}

/// Create a Phoenix heartbeat reply.
pub fn heartbeat_reply(ref: Option(String)) -> Frame {
  TextFrame(
    json.to_string(
      json.preprocessed_array([
        json.null(),
        option_to_json(ref),
        json.string("phoenix"),
        json.string("phx_reply"),
        json.object([
          #("status", json.string("ok")),
          #("response", json.object([])),
        ]),
      ]),
    ),
  )
}

fn option_to_json(opt: Option(String)) -> json.Json {
  case opt {
    None -> json.null()
    Some(s) -> json.string(s)
  }
}

/// Format a `DecodeError` as a human-readable string.
pub fn format_decode_error(error: DecodeError) -> String {
  codec.format_decode_error(error)
}
