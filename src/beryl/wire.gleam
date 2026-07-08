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
  type ReplyStatus, Event, Heartbeat, Inbound, InvalidFormat, InvalidJson, Join,
  Leave, StatusError, StatusOk, TextFrame,
}
import gleam/bool
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

const expected_array_message = "Expected array of 5 elements [join_ref, ref, topic, event, payload]"

const max_json_nesting_depth = 64

/// The canonical Phoenix wire codec. Pass to `beryl.config/1`.
pub fn phoenix_codec() -> Codec {
  codec.new(
    decode_text: decode_message,
    encode_reply: reply_json,
    encode_push: push,
    encode_heartbeat_reply: heartbeat_reply,
  )
  |> codec.with_close_encoder(channel_close)
  |> codec.with_error_encoder(channel_error)
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
      kind: classify_phoenix_event(topic, event),
      payload: payload,
    ))
  }

  case decode.run(value, wire_decoder) {
    Ok(msg) -> validate_inbound_depth(msg)
    Error(_) -> Error(InvalidFormat(expected_array_message))
  }
}

fn validate_inbound_depth(msg: Inbound) -> Result(Inbound, DecodeError) {
  use <- bool.guard(
    when: !within_json_depth(msg.payload, max_json_nesting_depth),
    return: Error(InvalidFormat("JSON nesting depth exceeded")),
  )
  Ok(msg)
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

/// Classify a Phoenix event name into a structural kind.
///
/// `phx_join`/`phx_leave` are reserved event names on every topic, but
/// `heartbeat` is only special on the reserved `"phoenix"` topic — an
/// application is free to define its own `"heartbeat"` channel event, which
/// must reach `handle_in` rather than refresh the socket's liveness timer.
fn classify_phoenix_event(topic: String, event: String) -> InboundKind {
  case topic, event {
    _, "phx_join" -> Join
    _, "phx_leave" -> Leave
    "phoenix", "heartbeat" -> Heartbeat
    _, other -> Event(other)
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
  dynamic_to_json_limited(value, max_json_nesting_depth)
  |> result.unwrap(json.null())
}

fn dynamic_to_json_limited(
  value: Dynamic,
  remaining_depth: Int,
) -> Result(json.Json, Nil) {
  decode.run(value, decode.string)
  |> result.map(json.string)
  |> result.replace_error(Nil)
  |> result.lazy_or(fn() { try_decode_int(value, remaining_depth) })
}

fn try_decode_int(
  value: Dynamic,
  remaining_depth: Int,
) -> Result(json.Json, Nil) {
  decode.run(value, decode.int)
  |> result.map(json.int)
  |> result.replace_error(Nil)
  |> result.lazy_or(fn() { try_decode_float(value, remaining_depth) })
}

fn try_decode_float(
  value: Dynamic,
  remaining_depth: Int,
) -> Result(json.Json, Nil) {
  decode.run(value, decode.float)
  |> result.map(json.float)
  |> result.replace_error(Nil)
  |> result.lazy_or(fn() { try_decode_bool(value, remaining_depth) })
}

fn try_decode_bool(
  value: Dynamic,
  remaining_depth: Int,
) -> Result(json.Json, Nil) {
  decode.run(value, decode.bool)
  |> result.map(json.bool)
  |> result.replace_error(Nil)
  |> result.lazy_or(fn() { try_decode_complex(value, remaining_depth) })
}

fn try_decode_complex(
  value: Dynamic,
  remaining_depth: Int,
) -> Result(json.Json, Nil) {
  case dynamic.classify(value) {
    "Nil" -> Ok(json.null())
    "List" -> decode_list_to_json(value, remaining_depth)
    _ -> decode_object_to_json(value, remaining_depth)
  }
}

fn decode_list_to_json(
  value: Dynamic,
  remaining_depth: Int,
) -> Result(json.Json, Nil) {
  use _ <- result.try(require_depth(remaining_depth))
  use items <- result.try(
    decode.run(value, decode.list(decode.dynamic))
    |> result.replace_error(Nil),
  )
  items
  |> list.map(fn(item) { dynamic_to_json_limited(item, remaining_depth - 1) })
  |> result.all()
  |> result.map(json.preprocessed_array)
}

fn decode_object_to_json(
  value: Dynamic,
  remaining_depth: Int,
) -> Result(json.Json, Nil) {
  use _ <- result.try(require_depth(remaining_depth))
  let dict_decoder = decode.dict(decode.string, decode.dynamic)
  use decoded <- result.try(
    decode.run(value, dict_decoder)
    |> result.replace_error(Nil),
  )
  decoded
  |> dict.to_list()
  |> list.map(fn(pair) {
    let #(key, nested) = pair
    dynamic_to_json_limited(nested, remaining_depth - 1)
    |> result.map(fn(json_value) { #(key, json_value) })
  })
  |> result.all()
  |> result.map(json.object)
}

fn require_depth(remaining_depth: Int) -> Result(Nil, Nil) {
  use <- bool.guard(when: remaining_depth <= 0, return: Error(Nil))
  Ok(Nil)
}

fn within_json_depth(value: Dynamic, remaining_depth: Int) -> Bool {
  case
    decode.run(value, decode.list(decode.dynamic))
    |> result.replace_error(Nil)
  {
    Ok(items) ->
      remaining_depth > 0
      && list.all(items, fn(item) {
        within_json_depth(item, remaining_depth - 1)
      })
    Error(Nil) -> within_object_depth(value, remaining_depth)
  }
}

fn within_object_depth(value: Dynamic, remaining_depth: Int) -> Bool {
  let dict_decoder = decode.dict(decode.string, decode.dynamic)
  case decode.run(value, dict_decoder) |> result.replace_error(Nil) {
    Ok(fields) ->
      remaining_depth > 0
      && fields
      |> dict.values()
      |> list.all(fn(nested) { within_json_depth(nested, remaining_depth - 1) })
    Error(Nil) -> True
  }
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

/// Create a Phoenix `phx_close` frame, sent when a channel terminates
/// gracefully. Phoenix mirrors the channel's `join_ref` into the `ref` slot.
pub fn channel_close(join_ref: Option(String), topic: String) -> Frame {
  terminal_event(join_ref, topic, "phx_close")
}

/// Create a Phoenix `phx_error` frame, sent when a channel terminates
/// abnormally. Phoenix clients respond by scheduling an automatic rejoin.
pub fn channel_error(join_ref: Option(String), topic: String) -> Frame {
  terminal_event(join_ref, topic, "phx_error")
}

fn terminal_event(
  join_ref: Option(String),
  topic: String,
  event: String,
) -> Frame {
  let join_ref_json = option_to_json(join_ref)
  TextFrame(
    json.to_string(
      json.preprocessed_array([
        join_ref_json,
        join_ref_json,
        json.string(topic),
        json.string(event),
        json.object([]),
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
