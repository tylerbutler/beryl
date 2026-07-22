//// Phoenix Wire Protocol — encoding/decoding helpers and the canonical
//// `phoenix_codec()` for `beryl/wire/codec`.
////
//// Phoenix uses a JSON array format: `[join_ref, ref, topic, event, payload]`.
//// This module parses and emits that format, and exposes a `Codec` value
//// that plugs the Phoenix framing into the runtime.
////
//// To use Phoenix framing (the historical default) construct beryl with:
////
//// ```gleam
//// beryl.config(wire.phoenix_codec())
//// ```

import beryl/wire/codec.{
  type Codec, type DecodeError, type Frame, type Inbound, type InboundKind,
  type ReplyStatus, Event, Heartbeat, InvalidFormat, InvalidJson, Join, Leave,
  StatusError, StatusOk, TextFrame,
}
import gleam/bit_array
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
///
/// Handles both the JSON array framing on text frames and the Phoenix V2
/// binary framing on binary frames (see `decode_binary_message`). Binary
/// push payloads reach the app's `update` as a `Binary` event (raw bytes as
/// `BitArray` wrapped in `Dynamic` at the wire layer); decode with
/// `gleam/dynamic/decode.bit_array` if needed.
pub fn phoenix_codec() -> Codec {
  codec.new(
    decode_text: decode_message,
    encode_reply: reply_json,
    encode_push: push,
    encode_heartbeat_reply: heartbeat_reply,
  )
  |> codec.with_close_encoder(channel_close)
  |> codec.with_error_encoder(channel_error)
  |> codec.with_binary_decoder(decode_binary_message)
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
    decode.success(codec.inbound(
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
    when: !within_json_depth(codec.inbound_payload(msg), max_json_nesting_depth),
    return: Error(InvalidFormat("JSON nesting depth exceeded")),
  )
  Ok(msg)
}

/// Encode an `Inbound` back to a Phoenix wire JSON string.
pub fn encode(msg: Inbound) -> String {
  let join_ref_json = option_to_json(codec.inbound_join_ref(msg))
  let ref_json = option_to_json(codec.inbound_ref(msg))
  let payload_json = dynamic_to_json(codec.inbound_payload(msg))
  let event = phoenix_event_name(codec.inbound_kind(msg))

  json.to_string(
    json.preprocessed_array([
      join_ref_json,
      ref_json,
      json.string(codec.inbound_topic(msg)),
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
/// must reach the app's `update` as a `Message` event rather than refresh
/// the socket's liveness timer.
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

// ── Phoenix V2 binary framing ───────────────────────────────────────────────
//
// Phoenix clients switch to a compact binary framing whenever a push payload
// is raw bytes (an ArrayBuffer in the JS client). Frames start with a kind
// byte, then u8 lengths for each metadata component, then the components,
// then the payload as the remaining bytes:
//
//   client push:      <<0, jr_len, ref_len, topic_len, event_len,
//                       jr, ref, topic, event, payload>>
//   server push:      <<0, jr_len, topic_len, event_len, jr, topic, event, payload>>
//   server reply:     <<1, jr_len, ref_len, topic_len, status_len,
//                       jr, ref, topic, status, payload>>
//   server broadcast: <<2, topic_len, event_len, topic, event, payload>>

const binary_push_kind = 0

const binary_reply_kind = 1

const binary_broadcast_kind = 2

const expected_binary_message = "Expected Phoenix V2 binary push frame"

/// Decode a Phoenix V2 binary push frame from a client into an `Inbound`.
///
/// The payload is delivered to the app's `update` as a `Binary` event
/// (raw bytes as `BitArray` wrapped in `Dynamic` at the wire layer); decode
/// it with `gleam/dynamic/decode.bit_array` if needed. Zero-length
/// join_ref/ref components decode as `None`. Reserved protocol events are
/// classified the same way as on the text framing.
pub fn decode_binary_message(data: BitArray) -> Result(Inbound, DecodeError) {
  case data {
    <<
      0,
      join_ref_size,
      ref_size,
      topic_size,
      event_size,
      join_ref:bytes-size(join_ref_size),
      ref:bytes-size(ref_size),
      topic:bytes-size(topic_size),
      event:bytes-size(event_size),
      payload:bytes,
    >> -> {
      use join_ref <- result.try(optional_utf8(join_ref))
      use ref <- result.try(optional_utf8(ref))
      use topic <- result.try(required_utf8(topic, "topic"))
      use event <- result.try(required_utf8(event, "event"))
      Ok(codec.inbound(
        join_ref: join_ref,
        ref: ref,
        topic: topic,
        kind: classify_phoenix_event(topic, event),
        payload: dynamic.bit_array(payload),
      ))
    }
    _ -> Error(InvalidFormat(expected_binary_message))
  }
}

fn optional_utf8(bytes: BitArray) -> Result(Option(String), DecodeError) {
  case bit_array.byte_size(bytes) {
    0 -> Ok(None)
    _ ->
      required_utf8(bytes, "ref")
      |> result.map(Some)
  }
}

fn required_utf8(bytes: BitArray, name: String) -> Result(String, DecodeError) {
  bit_array.to_string(bytes)
  |> result.replace_error(InvalidFormat(name <> " is not valid UTF-8"))
}

/// Encode a Phoenix V2 binary server push: `(join_ref, topic, event, payload)`.
///
/// Errors when a metadata component exceeds the framing's 255-byte length
/// limit.
pub fn binary_push(
  join_ref join_ref: Option(String),
  topic topic: String,
  event event: String,
  payload payload: BitArray,
) -> Result(Frame, Nil) {
  use #(jr_size, jr) <- result.try(u8_component(option.unwrap(join_ref, "")))
  use #(topic_size, topic) <- result.try(u8_component(topic))
  use #(event_size, event) <- result.try(u8_component(event))
  Ok(
    codec.BinaryFrame(<<
      binary_push_kind,
      jr_size,
      topic_size,
      event_size,
      jr:bits,
      topic:bits,
      event:bits,
      payload:bits,
    >>),
  )
}

/// Encode a Phoenix V2 binary reply: `(join_ref, ref, topic, status, payload)`.
///
/// Errors when a metadata component exceeds the framing's 255-byte length
/// limit.
pub fn binary_reply(
  join_ref join_ref: Option(String),
  ref ref: Option(String),
  topic topic: String,
  status status: ReplyStatus,
  payload payload: BitArray,
) -> Result(Frame, Nil) {
  let status_string = case status {
    StatusOk -> "ok"
    StatusError -> "error"
  }
  use #(jr_size, jr) <- result.try(u8_component(option.unwrap(join_ref, "")))
  use #(ref_size, ref) <- result.try(u8_component(option.unwrap(ref, "")))
  use #(topic_size, topic) <- result.try(u8_component(topic))
  use #(status_size, status) <- result.try(u8_component(status_string))
  Ok(
    codec.BinaryFrame(<<
      binary_reply_kind,
      jr_size,
      ref_size,
      topic_size,
      status_size,
      jr:bits,
      ref:bits,
      topic:bits,
      status:bits,
      payload:bits,
    >>),
  )
}

/// Encode a Phoenix V2 binary broadcast: `(topic, event, payload)`.
///
/// Errors when a metadata component exceeds the framing's 255-byte length
/// limit.
pub fn binary_broadcast(
  topic topic: String,
  event event: String,
  payload payload: BitArray,
) -> Result(Frame, Nil) {
  use #(topic_size, topic) <- result.try(u8_component(topic))
  use #(event_size, event) <- result.try(u8_component(event))
  Ok(
    codec.BinaryFrame(<<
      binary_broadcast_kind,
      topic_size,
      event_size,
      topic:bits,
      event:bits,
      payload:bits,
    >>),
  )
}

fn u8_component(value: String) -> Result(#(Int, BitArray), Nil) {
  let bytes = bit_array.from_string(value)
  let size = bit_array.byte_size(bytes)
  case size <= 255 {
    True -> Ok(#(size, bytes))
    False -> Error(Nil)
  }
}

/// Format a `DecodeError` as a human-readable string.
pub fn format_decode_error(error: DecodeError) -> String {
  codec.format_decode_error(error)
}
