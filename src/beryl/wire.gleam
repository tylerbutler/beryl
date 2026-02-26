//// Phoenix Wire Protocol - Encoding and decoding
////
//// Phoenix uses a JSON array format: [join_ref, ref, topic, event, payload]
//// This module handles parsing incoming messages and encoding outgoing ones.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// Phoenix wire message format
/// [join_ref, ref, topic, event, payload]
pub type WireMessage {
  WireMessage(
    /// Reference from the join that this message relates to (for reply routing)
    join_ref: Option(String),
    /// Unique reference for this specific message (for reply matching)
    ref: Option(String),
    /// Topic name (e.g., "room:lobby")
    topic: String,
    /// Event name (e.g., "phx_join", "new_message")
    event: String,
    /// JSON payload
    payload: Dynamic,
  )
}

/// Errors that can occur when parsing wire messages
pub type DecodeError {
  InvalidJson(String)
  InvalidFormat(String)
  MissingField(String)
}

/// Reply status for phx_reply messages
pub type ReplyStatus {
  StatusOk
  StatusError
}

/// Parse a JSON string into a WireMessage
///
/// Expected format: [join_ref, ref, topic, event, payload]
/// where join_ref and ref can be null
pub fn decode_message(json_string: String) -> Result(WireMessage, DecodeError) {
  // Create a decoder for the wire message array format
  // Using subfield with integer keys to index into the array
  let wire_decoder = {
    use join_ref <- decode.subfield([0], decode.optional(decode.string))
    use ref <- decode.subfield([1], decode.optional(decode.string))
    use topic <- decode.subfield([2], decode.string)
    use event <- decode.subfield([3], decode.string)
    use payload <- decode.subfield([4], decode.dynamic)
    decode.success(WireMessage(
      join_ref: join_ref,
      ref: ref,
      topic: topic,
      event: event,
      payload: payload,
    ))
  }

  case json.parse(from: json_string, using: wire_decoder) {
    Ok(msg) -> Ok(msg)
    Error(json.UnexpectedEndOfInput) ->
      Error(InvalidJson("Unexpected end of input"))
    Error(json.UnexpectedByte(byte)) ->
      Error(InvalidJson("Unexpected byte: " <> byte))
    Error(json.UnexpectedSequence(seq)) ->
      Error(InvalidJson("Unexpected sequence: " <> seq))
    Error(json.UnableToDecode(_)) ->
      Error(InvalidFormat(
        "Expected array of 5 elements [join_ref, ref, topic, event, payload]",
      ))
  }
}

/// Encode a WireMessage to a JSON string
///
/// Output format: [join_ref, ref, topic, event, payload]
pub fn encode(msg: WireMessage) -> String {
  let join_ref_json = case msg.join_ref {
    None -> json.null()
    Some(s) -> json.string(s)
  }

  let ref_json = case msg.ref {
    None -> json.null()
    Some(s) -> json.string(s)
  }

  // Convert Dynamic payload to Json
  let payload_json = dynamic_to_json(msg.payload)

  json.to_string(
    json.preprocessed_array([
      join_ref_json,
      ref_json,
      json.string(msg.topic),
      json.string(msg.event),
      payload_json,
    ]),
  )
}

/// Convert a Dynamic value to Json for encoding.
///
/// Handles strings, ints, floats, bools, nil, lists, and string-keyed dicts.
/// Falls back to `json.null()` for unrecognized types.
pub fn dynamic_to_json(value: Dynamic) -> json.Json {
  // Try decoding as various types
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
  // Check for nil/null
  case dynamic.classify(value) {
    "Nil" -> json.null()
    "List" -> {
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> json.preprocessed_array(list.map(items, dynamic_to_json))
        Error(_) -> json.null()
      }
    }
    _ -> {
      // Try to decode as a dict/map
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

/// Create a phx_reply message as a JSON string
///
/// Phoenix reply format: ["join_ref", "ref", "topic", "phx_reply", {"status": "ok"|"error", "response": ...}]
pub fn reply_json(
  join_ref: Option(String),
  ref: String,
  topic: String,
  status: ReplyStatus,
  response: json.Json,
) -> String {
  let status_string = case status {
    StatusOk -> "ok"
    StatusError -> "error"
  }

  let payload =
    json.object([
      #("status", json.string(status_string)),
      #("response", response),
    ])

  json.to_string(
    json.preprocessed_array([
      option_to_json(join_ref),
      json.string(ref),
      json.string(topic),
      json.string("phx_reply"),
      payload,
    ]),
  )
}

/// Create a push message (server-initiated, no ref)
pub fn push(topic: String, event: String, payload: json.Json) -> String {
  json.to_string(
    json.preprocessed_array([
      json.null(),
      json.null(),
      json.string(topic),
      json.string(event),
      payload,
    ]),
  )
}

/// Create a heartbeat reply
pub fn heartbeat_reply(ref: String) -> String {
  json.to_string(
    json.preprocessed_array([
      json.null(),
      json.string(ref),
      json.string("phoenix"),
      json.string("phx_reply"),
      json.object([
        #("status", json.string("ok")),
        #("response", json.object([])),
      ]),
    ]),
  )
}

fn option_to_json(opt: Option(String)) -> json.Json {
  case opt {
    None -> json.null()
    Some(s) -> json.string(s)
  }
}

/// Check if this is a Phoenix system event
pub fn is_system_event(event: String) -> Bool {
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

/// Format a decode error as a human-readable string
pub fn format_decode_error(error: DecodeError) -> String {
  case error {
    InvalidJson(msg) -> "Invalid JSON: " <> msg
    InvalidFormat(msg) -> "Invalid format: " <> msg
    MissingField(name) -> "Missing required field: " <> name
  }
}
