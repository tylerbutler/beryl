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
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

const expected_array_message = "Expected array of 5 elements [join_ref, ref, topic, event, payload]"

/// The canonical Phoenix wire codec. Pass to `beryl.config/1`.
pub fn phoenix_codec() -> Codec {
  Codec(
    decode_text: decode_message,
    decode_binary: None,
    encode_reply: reply_json,
    encode_push: push,
    encode_heartbeat_reply: heartbeat_reply,
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
  case decode.run(value, decode.string) {
    Ok(s) -> json.string(s)
    Error(_) -> try_decode_int(value)
  }
}

fn try_decode_int(value: Dynamic) -> json.Json {
  case decode.run(value, decode.int) {
    Ok(i) -> json.int(i)
    Error(_) -> try_decode_float(value)
  }
}

fn try_decode_float(value: Dynamic) -> json.Json {
  case decode.run(value, decode.float) {
    Ok(f) -> json.float(f)
    Error(_) -> try_decode_bool(value)
  }
}

fn try_decode_bool(value: Dynamic) -> json.Json {
  case decode.run(value, decode.bool) {
    Ok(b) -> json.bool(b)
    Error(_) -> try_decode_complex(value)
  }
}

fn try_decode_complex(value: Dynamic) -> json.Json {
  case dynamic.classify(value) {
    "Nil" -> json.null()
    "List" -> {
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> json.preprocessed_array(list.map(items, dynamic_to_json))
        Error(_) -> json.null()
      }
    }
    _ -> {
      let dict_decoder = decode.dict(decode.string, decode.dynamic)
      case decode.run(value, dict_decoder) {
        Ok(d) -> {
          let pairs =
            d
            |> dict.to_list()
            |> list.map(fn(pair) {
              let #(k, v) = pair
              #(k, dynamic_to_json(v))
            })
          json.object(pairs)
        }
        Error(_) -> json.null()
      }
    }
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

/// Check if this is a Phoenix system event.
///
/// Note: This is Phoenix-specific. The coordinator dispatches decoded messages
/// structurally using `codec.InboundKind` rather than consulting this helper.
pub fn is_phoenix_system_event(event: String) -> Bool {
  case event {
    "phx_join"
    | "phx_leave"
    | "phx_reply"
    | "phx_error"
    | "phx_close"
    | "heartbeat" -> True
    _ -> False
  }
}

/// Deprecated: renamed to `is_phoenix_system_event` to clarify the
/// Phoenix-specific event name set. Forwards to the new name.
@deprecated("Use is_phoenix_system_event/1")
pub fn is_system_event(event: String) -> Bool {
  is_phoenix_system_event(event)
}

/// Format a `DecodeError` as a human-readable string.
pub fn format_decode_error(error: DecodeError) -> String {
  codec.format_decode_error(error)
}
