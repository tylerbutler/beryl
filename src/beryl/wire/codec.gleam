//// Pluggable wire codec for beryl.
////
//// A `Codec` plugs the coordinator into any over-the-wire framing. The
//// canonical implementation is `beryl/wire.phoenix_codec()`, which ships
//// the Phoenix array format (`[join_ref, ref, topic, event, payload]`).
////
//// To run beryl over your own framing, build a `Codec` value and pass it
//// to `beryl.config(codec)`. The coordinator decodes inbound text via
//// `codec.decode_text`, optionally decodes inbound binary via
//// `codec.decode_binary`, dispatches based on the structural `InboundKind`,
//// and produces outbound text or binary frames via `codec.encode_*` helpers.
////
//// All codecs must normalise inbound traffic to the `Inbound` shape so
//// the coordinator can stay framing-agnostic.

import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/option.{type Option}

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
/// - `join_ref`: optional client-side reference assigned at join time
///   (used by some Phoenix replies; codecs without this concept should
///   pass `None`)
/// - `ref`: optional per-message reference for reply correlation
/// - `topic`: subscription topic (e.g. `"room:lobby"`, `"doc:abc"`)
/// - `kind`: structural protocol event or user event
/// - `payload`: message body as a `Dynamic` for the channel handler to
///   decode
pub type Inbound {
  Inbound(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    kind: InboundKind,
    payload: Dynamic,
  )
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
/// coordinator's log messages and by `wire.format_decode_error`.
pub fn format_decode_error(error: DecodeError) -> String {
  case error {
    InvalidJson(reason) -> "Invalid JSON: " <> reason
    InvalidFormat(reason) -> "Invalid format: " <> reason
    MissingField(name) -> "Missing required field: " <> name
  }
}

/// A wire codec.
pub type Codec {
  Codec(
    /// Decode raw inbound text into a normalised `Inbound`.
    decode_text: fn(String) -> Result(Inbound, DecodeError),
    /// Decode raw inbound binary into a normalised `Inbound`.
    ///
    /// When `None`, binary WebSocket frames are routed to `channel.handle_binary`
    /// as raw data for backwards compatibility.
    decode_binary: Option(fn(BitArray) -> Result(Inbound, DecodeError)),
    /// Encode a reply to a client message: `(join_ref, ref, topic, status, response_payload)`.
    encode_reply: fn(
      Option(String),
      Option(String),
      String,
      ReplyStatus,
      json.Json,
    ) -> Frame,
    /// Encode a server-initiated push: `(topic, event, payload)`.
    encode_push: fn(String, String, json.Json) -> Frame,
    /// Encode a heartbeat reply for a given client `ref`.
    encode_heartbeat_reply: fn(Option(String)) -> Frame,
  )
}
