//// Pluggable wire codec for beryl.
////
//// A `Codec` plugs the coordinator into any over-the-wire framing. The
//// canonical implementation is `beryl/wire.phoenix_codec()`, which ships
//// the Phoenix array format (`[join_ref, ref, topic, event, payload]`).
////
//// To run beryl over your own framing, build a `Codec` value and pass it
//// to `beryl.config(codec)`. The coordinator decodes inbound bytes via
//// `codec.decode`, dispatches based on the `event` string against the
//// codec's `join_event`, `leave_event`, and `heartbeat_event` constants,
//// and produces outbound bytes via `codec.encode_*` helpers.
////
//// All codecs must normalise inbound traffic to the `Inbound` shape so
//// the coordinator can stay framing-agnostic.

import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/option.{type Option}

/// Normalised inbound message shape.
///
/// - `join_ref`: optional client-side reference assigned at join time
///   (used by some Phoenix replies; codecs without this concept should
///   pass `None`)
/// - `ref`: optional per-message reference for reply correlation
/// - `topic`: subscription topic (e.g. `"room:lobby"`, `"doc:abc"`)
/// - `event`: event/kind discriminator (e.g. `"new_message"`, `"delta"`,
///   or system events like the codec's `join_event`)
/// - `payload`: message body as a `Dynamic` for the channel handler to
///   decode
pub type Inbound {
  Inbound(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: Dynamic,
  )
}

/// Errors a codec may emit when decoding inbound bytes.
pub type DecodeError {
  InvalidJson(reason: String)
  InvalidFormat(reason: String)
  MissingField(name: String)
}

/// Status of a reply produced by a channel handler.
pub type ReplyStatus {
  StatusOk
  StatusError
}

/// A wire codec.
pub type Codec {
  Codec(
    /// Decode raw inbound text into a normalised `Inbound`.
    decode: fn(String) -> Result(Inbound, DecodeError),
    /// Encode a reply to a client message: `(join_ref, ref, topic, status, response_payload)`.
    encode_reply: fn(Option(String), String, String, ReplyStatus, json.Json) ->
      String,
    /// Encode a server-initiated push: `(topic, event, payload)`.
    encode_push: fn(String, String, json.Json) -> String,
    /// Encode a heartbeat reply for a given client `ref`.
    encode_heartbeat_reply: fn(String) -> String,
    /// Event name signalling a client wants to join a topic.
    join_event: String,
    /// Event name signalling a client wants to leave a topic.
    leave_event: String,
    /// Event name signalling a heartbeat ping.
    heartbeat_event: String,
  )
}
