//// Pluggable wire codec for beryl.
////
//// A `Codec` plugs the runtime into any over-the-wire framing. The
//// canonical implementation is `beryl/wire.phoenix_codec()`, which ships
//// the Phoenix array format (`[join_ref, ref, topic, event, payload]`).
////
//// To run beryl over your own framing, build a `Codec` value and pass it
//// to `beryl.config(codec)`. The runtime decodes inbound frames and produces
//// outbound frames using the configured callbacks. Codec authors can exercise
//// those callbacks directly with the public `apply_*` functions.
////
//// All codecs must normalise inbound traffic to the `Inbound` shape so
//// the runtime can stay framing-agnostic.

import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/option.{type Option, None, Some}

/// Encoded WebSocket frame returned by a codec.
pub type Frame {
  /// A UTF-8 text frame.
  TextFrame(String)
  /// A binary frame.
  BinaryFrame(BitArray)
}

/// Structural inbound message kind used for protocol dispatch.
pub type InboundKind {
  /// A client joining a topic.
  Join
  /// A client leaving a topic.
  Leave
  /// A heartbeat/keep-alive message.
  Heartbeat
  /// A user-defined event; the wrapped `String` is the event name.
  Event(String)
}

/// A normalized inbound message.
///
/// `Inbound` is opaque: construct it with `inbound` and read it with the
/// `inbound_*` accessors. The hidden record lets Beryl add fields with
/// defaults without breaking custom codecs.
pub opaque type Inbound {
  Inbound(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    kind: InboundKind,
    payload: Dynamic,
  )
}

/// Construct a normalized inbound message.
///
/// - `join_ref`: optional client-side reference assigned at join time
///   (used by some Phoenix replies; codecs without this concept should
///   pass `None`)
/// - `ref`: optional per-message reference for reply correlation
/// - `topic`: subscription topic (e.g. `"room:lobby"`, `"doc:abc"`)
/// - `kind`: structural protocol event or user event
/// - `payload`: message body as a `Dynamic` for the app to decode
pub fn inbound(
  join_ref join_ref: Option(String),
  ref ref: Option(String),
  topic topic: String,
  kind kind: InboundKind,
  payload payload: Dynamic,
) -> Inbound {
  Inbound(join_ref:, ref:, topic:, kind:, payload:)
}

/// Return the inbound message's join-time client reference, if any.
pub fn inbound_join_ref(inbound: Inbound) -> Option(String) {
  inbound.join_ref
}

/// Return the inbound message's per-message reply reference, if any.
pub fn inbound_ref(inbound: Inbound) -> Option(String) {
  inbound.ref
}

/// Return the inbound message's subscription topic.
pub fn inbound_topic(inbound: Inbound) -> String {
  inbound.topic
}

/// Return the inbound message's structural kind.
pub fn inbound_kind(inbound: Inbound) -> InboundKind {
  inbound.kind
}

/// Return the inbound message body for the app to decode.
pub fn inbound_payload(inbound: Inbound) -> Dynamic {
  inbound.payload
}

/// Errors a codec may emit when decoding inbound bytes.
pub type DecodeError {
  /// The bytes were not valid JSON; `reason` describes the parse error.
  InvalidJson(reason: String)
  /// The message was valid JSON but did not match the expected framing;
  /// `reason` describes the mismatch.
  InvalidFormat(reason: String)
  /// A required field was absent; `name` is the missing field.
  MissingField(name: String)
}

/// Status of a reply produced by the app.
pub type ReplyStatus {
  /// The handler succeeded (`"ok"` in Phoenix framing).
  StatusOk
  /// The handler failed (`"error"` in Phoenix framing).
  StatusError
}

/// Format a `DecodeError` as human-readable text.
///
/// The runtime log messages and `wire.format_decode_error` use this text.
pub fn format_decode_error(error: DecodeError) -> String {
  case error {
    InvalidJson(reason) -> "Invalid JSON: " <> reason
    InvalidFormat(reason) -> "Invalid format: " <> reason
    MissingField(name) -> "Missing required field: " <> name
  }
}

/// A wire codec.
///
/// `Codec` is opaque. Build one with `new`. For binary support, add
/// `with_binary_decoder`.
pub opaque type Codec {
  Codec(
    decode_text: fn(String) -> Result(Inbound, DecodeError),
    decode_binary: Option(fn(BitArray) -> Result(Inbound, DecodeError)),
    encode_reply: fn(
      Option(String),
      Option(String),
      String,
      ReplyStatus,
      json.Json,
    ) -> Frame,
    encode_push: fn(String, String, json.Json) -> Frame,
    encode_heartbeat_reply: fn(Option(String)) -> Frame,
    encode_close: Option(fn(Option(String), String) -> Frame),
    encode_error: Option(fn(Option(String), String) -> Frame),
    topicless_events: Bool,
  )
}

/// Build a text-only wire codec.
///
/// - `decode_text`: decode raw inbound text into a normalized `Inbound`.
/// - `encode_reply`: encode a reply to a client message:
///   `(join_ref, ref, topic, status, response_payload)`.
/// - `encode_push`: encode a server-initiated push: `(topic, event, payload)`.
/// - `encode_heartbeat_reply`: encode a heartbeat reply for a given client `ref`.
///
/// The resulting codec has no binary decoder; binary WebSocket frames are
/// delivered to the app's `update` as a raw `Binary` event. Add a binary
/// decoder with `with_binary_decoder`.
pub fn new(
  decode_text decode_text: fn(String) -> Result(Inbound, DecodeError),
  encode_reply encode_reply: fn(
    Option(String),
    Option(String),
    String,
    ReplyStatus,
    json.Json,
  ) -> Frame,
  encode_push encode_push: fn(String, String, json.Json) -> Frame,
  encode_heartbeat_reply encode_heartbeat_reply: fn(Option(String)) -> Frame,
) -> Codec {
  Codec(
    decode_text:,
    decode_binary: None,
    encode_reply:,
    encode_push:,
    encode_heartbeat_reply:,
    encode_close: None,
    encode_error: None,
    topicless_events: False,
  )
}

/// Add a binary decoder to a codec.
///
/// When set, the decoder converts binary WebSocket frames to a normalized
/// `Inbound` via `decode_binary`. The app's `update` function does not receive
/// a raw `Binary` event.
pub fn with_binary_decoder(
  codec: Codec,
  decode_binary: fn(BitArray) -> Result(Inbound, DecodeError),
) -> Codec {
  Codec(..codec, decode_binary: Some(decode_binary))
}

/// Add a topic-close encoder to a codec.
///
/// When set, the runtime sends this frame when one of the client's topics
/// terminates gracefully (leave, server shutdown, heartbeat
/// eviction): `(join_ref, topic)`. Phoenix clients rely on `phx_close` to
/// leave the joined state instead of waiting out push timeouts.
pub fn with_close_encoder(
  codec: Codec,
  encode_close: fn(Option(String), String) -> Frame,
) -> Codec {
  Codec(..codec, encode_close: Some(encode_close))
}

/// Add a topic-error encoder to a codec.
///
/// When set, the runtime sends this frame when one of the client's topics
/// terminates abnormally (crashed or stopped with an error):
/// `(join_ref, topic)`. Phoenix clients rely on `phx_error` to schedule an
/// automatic rejoin.
pub fn with_error_encoder(
  codec: Codec,
  encode_error: fn(Option(String), String) -> Frame,
) -> Codec {
  Codec(..codec, encode_error: Some(encode_error))
}

/// Decode a text frame with a codec.
///
/// Codec authors can use this to test the decoder supplied to `new`.
pub fn apply_decode_text(
  codec: Codec,
  text text: String,
) -> Result(Inbound, DecodeError) {
  codec.decode_text(text)
}

/// Decode a binary frame with a codec, if it has a binary decoder.
///
/// Returns `None` when the codec has no decoder configured with
/// `with_binary_decoder`.
pub fn apply_decode_binary(
  codec: Codec,
  data data: BitArray,
) -> Option(Result(Inbound, DecodeError)) {
  case codec.decode_binary {
    Some(decode) -> Some(decode(data))
    None -> None
  }
}

/// Encode a reply with a codec.
pub fn apply_encode_reply(
  codec: Codec,
  join_ref join_ref: Option(String),
  ref ref: Option(String),
  topic topic: String,
  status status: ReplyStatus,
  response response: json.Json,
) -> Frame {
  codec.encode_reply(join_ref, ref, topic, status, response)
}

/// Encode a server-initiated push with a codec.
pub fn apply_encode_push(
  codec: Codec,
  topic topic: String,
  event event: String,
  payload payload: json.Json,
) -> Frame {
  codec.encode_push(topic, event, payload)
}

/// Encode a heartbeat reply with a codec.
pub fn apply_encode_heartbeat_reply(
  codec: Codec,
  ref ref: Option(String),
) -> Frame {
  codec.encode_heartbeat_reply(ref)
}

/// Encode a graceful topic close with a codec, if it has a close encoder.
///
/// Returns `None` when the codec has no encoder configured with
/// `with_close_encoder`.
pub fn apply_encode_close(
  codec: Codec,
  join_ref join_ref: Option(String),
  topic topic: String,
) -> Option(Frame) {
  case codec.encode_close {
    Some(encode) -> Some(encode(join_ref, topic))
    None -> None
  }
}

/// Encode an abnormal topic termination with a codec, if it has an error
/// encoder.
///
/// Returns `None` when the codec has no encoder configured with
/// `with_error_encoder`.
pub fn apply_encode_error(
  codec: Codec,
  join_ref join_ref: Option(String),
  topic topic: String,
) -> Option(Frame) {
  case codec.encode_error {
    Some(encode) -> Some(encode(join_ref, topic))
    None -> None
  }
}

/// Accessor for the codec's text decoder.
@internal
pub fn decode_text(codec: Codec) -> fn(String) -> Result(Inbound, DecodeError) {
  codec.decode_text
}

/// Accessor for the codec's optional binary decoder.
@internal
pub fn decode_binary(
  codec: Codec,
) -> Option(fn(BitArray) -> Result(Inbound, DecodeError)) {
  codec.decode_binary
}

/// Accessor for the codec's reply encoder.
@internal
pub fn encode_reply(
  codec: Codec,
) -> fn(Option(String), Option(String), String, ReplyStatus, json.Json) -> Frame {
  codec.encode_reply
}

/// Accessor for the codec's push encoder.
@internal
pub fn encode_push(codec: Codec) -> fn(String, String, json.Json) -> Frame {
  codec.encode_push
}

/// Accessor for the codec's heartbeat-reply encoder.
@internal
pub fn encode_heartbeat_reply(codec: Codec) -> fn(Option(String)) -> Frame {
  codec.encode_heartbeat_reply
}

/// Accessor for the codec's optional topic-close encoder.
@internal
pub fn encode_close(
  codec: Codec,
) -> Option(fn(Option(String), String) -> Frame) {
  codec.encode_close
}

/// Mark a codec's events as topicless.
///
/// Some framings, such as Socket.IO-style protocols, do not carry a per-frame
/// topic. When set, an inbound event whose topic is empty is routed to the
/// socket's single joined topic. The runtime drops it when the socket has
/// zero or multiple joins.
/// Topic-carrying codecs (like the Phoenix codec) must leave this off so
/// the runtime rejects empty-topic frames instead of inferring a topic.
pub fn with_topicless_events(codec: Codec) -> Codec {
  Codec(..codec, topicless_events: True)
}

/// Whether the codec routes events without an explicit topic.
///
/// Codec authors can use this to test `with_topicless_events`.
pub fn uses_topicless_events(codec: Codec) -> Bool {
  codec.topicless_events
}

/// Accessor for the codec's topicless-events flag.
@internal
pub fn topicless_events(codec: Codec) -> Bool {
  codec.topicless_events
}

/// Accessor for the codec's optional topic-error encoder.
@internal
pub fn encode_error(
  codec: Codec,
) -> Option(fn(Option(String), String) -> Frame) {
  codec.encode_error
}
