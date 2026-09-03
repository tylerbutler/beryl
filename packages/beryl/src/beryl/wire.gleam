//// Phoenix wire protocol: encoding and decoding helpers and the canonical
//// `phoenix_codec()` for `beryl/wire/codec`.
////
//// Phoenix uses a JSON array format: `[join_ref, ref, topic, event, payload]`.
//// This module parses and emits that format, and exposes a `Codec` value
//// that plugs the Phoenix framing into the runtime.
////
//// Phoenix framing must be selected explicitly when constructing beryl:
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
import gleam/string

const expected_array_message = "array of 5 elements [join_ref, ref, topic, event, payload]"

const max_json_nesting_depth = 64

const max_decode_error_length = 256

/// Return the canonical Phoenix wire codec.
///
/// Pass this codec to `beryl.config`.
///
/// The codec handles JSON array framing on text frames and Phoenix V2
/// binary framing on binary frames (see `decode_binary_message`). Decoded
/// binary frames follow the normal inbound path, producing `Join` or
/// `Message` events according to their event name. The app receives a
/// `Binary` event only for an undecoded frame from a codec without a binary
/// decoder.
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
/// Expected format: `[join_ref, ref, topic, event, payload]`. The `join_ref`
/// and `ref` values can be `null`.
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
      Error(InvalidFormat("Expected " <> expected_array_message))
  }
}

fn decode_inbound_value(value: Dynamic) -> Result(Inbound, DecodeError) {
  case decode.run(value, inbound_decoder()) {
    Ok(message) -> validate_inbound_depth(message)
    Error(errors) -> Error(InvalidFormat(format_decode_errors(errors)))
  }
}

fn inbound_decoder() -> decode.Decoder(Inbound) {
  decode.list(decode.dynamic)
  |> decode.then(fn(items) {
    case items {
      [_, _, _, _, _] -> inbound_fields_decoder()
      _ ->
        decode.failure(
          codec.inbound(None, None, "", Event(""), dynamic.nil()),
          expected: expected_array_message,
        )
    }
  })
}

fn inbound_fields_decoder() -> decode.Decoder(Inbound) {
  {
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
}

fn format_decode_errors(errors: List(decode.DecodeError)) -> String {
  errors
  |> list.map(fn(error) {
    let decode.DecodeError(expected, found, path) = error
    "Expected " <> expected <> format_decode_path(path) <> ", found " <> found
  })
  |> string.join("; ")
  |> string.slice(0, max_decode_error_length)
}

fn format_decode_path(path: List(String)) -> String {
  case path {
    [] -> ""
    [index] -> " at index " <> index
    _ -> " at path " <> string.join(path, ".")
  }
}

fn validate_inbound_depth(message: Inbound) -> Result(Inbound, DecodeError) {
  use <- bool.guard(
    when: !within_json_depth(
      codec.inbound_payload(message),
      max_json_nesting_depth,
    ),
    return: Error(InvalidFormat("JSON nesting depth exceeded")),
  )
  Ok(message)
}

/// Encode an `Inbound` as a Phoenix wire JSON string.
///
/// If the payload cannot be represented as JSON or exceeds the maximum
/// nesting depth, it is encoded as `null`.
pub fn encode(message: Inbound) -> String {
  let join_ref_json = option_to_json(codec.inbound_join_ref(message))
  let ref_json = option_to_json(codec.inbound_ref(message))
  // Decoded inbound payloads are depth-validated at `decode`, so conversion
  // only fails for hand-built payloads deeper than the wire limit; those
  // could not round-trip anyway and encode as null.
  let payload_json =
    dynamic_to_json(codec.inbound_payload(message))
    |> result.unwrap(json.null())
  let event = phoenix_event_name(codec.inbound_kind(message))

  json.to_string(
    json.preprocessed_array([
      join_ref_json,
      ref_json,
      json.string(codec.inbound_topic(message)),
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

/// Convert a `Dynamic` value decoded from JSON back to `json.Json`.
///
/// Returns `Error(Nil)` when the value exceeds the wire protocol's maximum
/// JSON depth or contains a value that JSON cannot represent.
pub fn dynamic_to_json(value: Dynamic) -> Result(json.Json, Nil) {
  dynamic_to_json_limited(value, max_json_nesting_depth)
}

fn dynamic_to_json_limited(
  value: Dynamic,
  remaining_depth: Int,
) -> Result(json.Json, Nil) {
  decode.run(value, json_decoder(remaining_depth))
  |> result.replace_error(Nil)
}

fn json_decoder(remaining_depth: Int) -> decode.Decoder(json.Json) {
  let scalar_decoder =
    decode.one_of(decode.string |> decode.map(json.string), [
      decode.int |> decode.map(json.int),
      decode.float |> decode.map(json.float),
      decode.bool |> decode.map(json.bool),
      decode.optional(decode.failure(json.null(), expected: "Nil"))
        |> decode.map(fn(_) { json.null() }),
    ])

  case remaining_depth <= 0 {
    True -> scalar_decoder
    False -> {
      let nested_decoder =
        decode.recursive(fn() { json_decoder(remaining_depth - 1) })
      decode.one_of(scalar_decoder, [
        decode.list(nested_decoder) |> decode.map(json.preprocessed_array),
        decode.dict(decode.string, nested_decoder)
          |> decode.map(fn(fields) { fields |> dict.to_list() |> json.object() }),
      ])
    }
  }
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

/// Create a Phoenix `phx_close` frame for a normal channel termination.
///
/// Phoenix copies the channel's `join_ref` to the `ref` slot.
pub fn channel_close(join_ref: Option(String), topic: String) -> Frame {
  terminal_event(join_ref, topic, "phx_close")
}

/// Create a Phoenix `phx_error` frame for an abnormal channel termination.
///
/// Phoenix clients respond by scheduling an automatic rejoin.
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
/// The payload remains a `BitArray` wrapped in `Dynamic`. The decoded
/// frame follows normal event classification and reaches the app as a
/// `Join` or `Message` event rather than `Binary`. Decode the payload with
/// `gleam/dynamic/decode.bit_array` if needed. Zero-length `join_ref` and
/// `ref` components decode as `None`. Reserved protocol events use the same
/// classification as text frames.
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

/// An error returned when encoding a Phoenix binary frame.
pub type BinaryEncodeError {
  /// A metadata component is too large for the protocol's one-byte length.
  MetadataTooLong(component: String, byte_size: Int)
}

/// Encode a Phoenix V2 binary server push: `(join_ref, topic, event, payload)`.
///
/// Returns `Error(MetadataTooLong(component, byte_size))` when a metadata
/// component exceeds the framing's 255-byte limit.
pub fn binary_push(
  join_ref join_ref: Option(String),
  topic topic: String,
  event event: String,
  payload payload: BitArray,
) -> Result(Frame, BinaryEncodeError) {
  use #(join_ref_size, join_ref_bytes) <- result.try(u8_component(
    option.unwrap(join_ref, ""),
    "join_ref",
  ))
  use #(topic_size, topic) <- result.try(u8_component(topic, "topic"))
  use #(event_size, event) <- result.try(u8_component(event, "event"))
  Ok(
    codec.BinaryFrame(<<
      binary_push_kind,
      join_ref_size,
      topic_size,
      event_size,
      join_ref_bytes:bits,
      topic:bits,
      event:bits,
      payload:bits,
    >>),
  )
}

/// Encode a Phoenix V2 binary reply: `(join_ref, ref, topic, status, payload)`.
///
/// Returns `Error(MetadataTooLong(component, byte_size))` when a metadata
/// component exceeds the framing's 255-byte limit.
pub fn binary_reply(
  join_ref join_ref: Option(String),
  ref ref: Option(String),
  topic topic: String,
  status status: ReplyStatus,
  payload payload: BitArray,
) -> Result(Frame, BinaryEncodeError) {
  let status_string = case status {
    StatusOk -> "ok"
    StatusError -> "error"
  }
  use #(join_ref_size, join_ref_bytes) <- result.try(u8_component(
    option.unwrap(join_ref, ""),
    "join_ref",
  ))
  use #(ref_size, ref) <- result.try(u8_component(option.unwrap(ref, ""), "ref"))
  use #(topic_size, topic) <- result.try(u8_component(topic, "topic"))
  use #(status_size, status) <- result.try(u8_component(status_string, "status"))
  Ok(
    codec.BinaryFrame(<<
      binary_reply_kind,
      join_ref_size,
      ref_size,
      topic_size,
      status_size,
      join_ref_bytes:bits,
      ref:bits,
      topic:bits,
      status:bits,
      payload:bits,
    >>),
  )
}

/// Encode a Phoenix V2 binary broadcast: `(topic, event, payload)`.
///
/// Returns `Error(MetadataTooLong(component, byte_size))` when a metadata
/// component exceeds the framing's 255-byte limit.
pub fn binary_broadcast(
  topic topic: String,
  event event: String,
  payload payload: BitArray,
) -> Result(Frame, BinaryEncodeError) {
  use #(topic_size, topic) <- result.try(u8_component(topic, "topic"))
  use #(event_size, event) <- result.try(u8_component(event, "event"))
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

fn u8_component(
  value: String,
  component: String,
) -> Result(#(Int, BitArray), BinaryEncodeError) {
  let bytes = bit_array.from_string(value)
  let size = bit_array.byte_size(bytes)
  case size <= 255 {
    True -> Ok(#(size, bytes))
    False -> Error(MetadataTooLong(component, size))
  }
}

/// Format a `DecodeError` as a human-readable string.
pub fn format_decode_error(error: DecodeError) -> String {
  codec.format_decode_error(error)
}
