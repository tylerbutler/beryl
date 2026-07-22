//// Pluggable wire codec for beryl.
////
//// A `Codec` plugs the runtime into any over-the-wire framing. The
//// canonical implementation is `beryl/wire.phoenix_codec()`, which ships
//// the Phoenix array format (`[join_ref, ref, topic, event, payload]`).
////
//// To run beryl over your own framing, build a `Codec` value and pass it
//// to `beryl.config(codec)`. The runtime decodes inbound text via
//// `codec.decode_text`, optionally decodes inbound binary via
//// `codec.decode_binary`, dispatches based on the structural `InboundKind`,
//// and produces outbound text or binary frames via `codec.encode_*` helpers.
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

/// Normalised inbound message shape.
///
/// `Inbound` is opaque: construct it with `inbound` and read it with the
/// `inbound_*` accessors. Keeping the record hidden lets Beryl add fields
/// (which default sensibly) without breaking every custom codec.
pub opaque type Inbound {
  Inbound(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    kind: InboundKind,
    payload: Dynamic,
  )
}

/// Construct a normalised inbound message.
///
/// - `join_ref`: optional client-side reference assigned at join time
///   (used by some Phoenix replies; codecs without this concept should
///   pass `None`)
/// - `ref`: optional per-message reference for reply correlation
/// - `topic`: subscription topic (e.g. `"room:lobby"`, `"doc:abc"`)
/// - `kind`: structural protocol event or user event
/// - `payload`: message body as a `Dynamic` for the channel handler to
///   decode
pub fn inbound(
  join_ref join_ref: Option(String),
  ref ref: Option(String),
  topic topic: String,
  kind kind: InboundKind,
  payload payload: Dynamic,
) -> Inbound {
  Inbound(join_ref:, ref:, topic:, kind:, payload:)
}

/// The inbound message's join-time client reference, if any.
pub fn inbound_join_ref(inbound: Inbound) -> Option(String) {
  inbound.join_ref
}

/// The inbound message's per-message reference for reply correlation, if any.
pub fn inbound_ref(inbound: Inbound) -> Option(String) {
  inbound.ref
}

/// The inbound message's subscription topic.
pub fn inbound_topic(inbound: Inbound) -> String {
  inbound.topic
}

/// The inbound message's structural kind.
pub fn inbound_kind(inbound: Inbound) -> InboundKind {
  inbound.kind
}

/// The inbound message's body, for the channel handler to decode.
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

/// Status of a reply produced by a channel handler.
pub type ReplyStatus {
  /// The handler succeeded (`"ok"` in Phoenix framing).
  StatusOk
  /// The handler failed (`"error"` in Phoenix framing).
  StatusError
}

/// Format a `DecodeError` as a human-readable string. Used by the
/// runtime's log messages and by `wire.format_decode_error`.
pub fn format_decode_error(error: DecodeError) -> String {
  case error {
    InvalidJson(reason) -> "Invalid JSON: " <> reason
    InvalidFormat(reason) -> "Invalid format: " <> reason
    MissingField(name) -> "Missing required field: " <> name
  }
}

/// A wire codec.
///
/// `Codec` is opaque; build one with `new` (and, for binary support,
/// `with_binary_decoder`). The runtime reads the codec's behaviour
/// through the `@internal` accessors below.
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
/// - `decode_text`: decode raw inbound text into a normalised `Inbound`.
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

/// Attach a binary decoder to a codec.
///
/// When set, binary WebSocket frames are decoded into a normalised `Inbound`
/// via `decode_binary` instead of being delivered to the app's `update` as a
/// raw `Binary` event.
pub fn with_binary_decoder(
  codec: Codec,
  decode_binary: fn(BitArray) -> Result(Inbound, DecodeError),
) -> Codec {
  Codec(..codec, decode_binary: Some(decode_binary))
}

/// Attach a channel-close encoder to a codec.
///
/// When set, the runtime emits this frame to a client whenever one of
/// its channels terminates gracefully (leave, server shutdown, heartbeat
/// eviction): `(join_ref, topic)`. Phoenix clients rely on `phx_close` to
/// leave the joined state instead of waiting out push timeouts.
pub fn with_close_encoder(
  codec: Codec,
  encode_close: fn(Option(String), String) -> Frame,
) -> Codec {
  Codec(..codec, encode_close: Some(encode_close))
}

/// Attach a channel-error encoder to a codec.
///
/// When set, the runtime emits this frame to a client whenever one of
/// its channels terminates abnormally (crashed or stopped with an error):
/// `(join_ref, topic)`. Phoenix clients rely on `phx_error` to schedule an
/// automatic rejoin.
pub fn with_error_encoder(
  codec: Codec,
  encode_error: fn(Option(String), String) -> Frame,
) -> Codec {
  Codec(..codec, encode_error: Some(encode_error))
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

/// Accessor for the codec's optional channel-close encoder.
@internal
pub fn encode_close(
  codec: Codec,
) -> Option(fn(Option(String), String) -> Frame) {
  codec.encode_close
}

/// Mark a codec's events as topicless.
///
/// Some framings (e.g. Socket.IO-style protocols) do not carry a per-frame
/// topic. When set, an inbound event whose topic is empty is routed to the
/// socket's single joined topic; with zero or multiple joins it is dropped.
/// Topic-carrying codecs (like the Phoenix codec) must leave this off so
/// empty-topic frames are rejected instead of guessed at.
pub fn with_topicless_events(codec: Codec) -> Codec {
  Codec(..codec, topicless_events: True)
}

/// Accessor for the codec's topicless-events flag.
@internal
pub fn topicless_events(codec: Codec) -> Bool {
  codec.topicless_events
}

/// Accessor for the codec's optional channel-error encoder.
@internal
pub fn encode_error(
  codec: Codec,
) -> Option(fn(Option(String), String) -> Frame) {
  codec.encode_error
}
