---
title: beryl/wire/codec
description: Pluggable wire codec for beryl.
---

Pluggable wire codec for beryl.

 A `Codec` plugs the coordinator into any over-the-wire framing. The
 canonical implementation is `beryl/wire.phoenix_codec()`, which ships
 the Phoenix array format (`[join_ref, ref, topic, event, payload]`).

 To run beryl over your own framing, build a `Codec` value and pass it
 to `beryl.config(codec)`. The coordinator decodes inbound text via
 `codec.decode_text`, optionally decodes inbound binary via
 `codec.decode_binary`, dispatches based on the structural `InboundKind`,
 and produces outbound text or binary frames via `codec.encode_*` helpers.

 All codecs must normalise inbound traffic to the `Inbound` shape so
 the coordinator can stay framing-agnostic.

## Types

### `Codec`

A wire codec.

```gleam
pub type Codec {
  Codec(
    decode_text: fn(String) -> Result(Inbound, DecodeError),
    decode_binary: option.Option(fn(BitArray) -> Result(Inbound, DecodeError)),
    encode_reply: fn(option.Option(String), option.Option(String), String, ReplyStatus, json.Json) -> Frame,
    encode_push: fn(String, String, json.Json) -> Frame,
    encode_heartbeat_reply: fn(option.Option(String)) -> Frame
  )
}
```

### `DecodeError`

Errors a codec may emit when decoding inbound bytes.

```gleam
pub type DecodeError {
  InvalidJson(reason: String)
  InvalidFormat(reason: String)
  MissingField(name: String)
}
```

#### Constructors

##### `InvalidJson(reason: String)`

The bytes were not valid JSON; `reason` describes the parse error.

##### `InvalidFormat(reason: String)`

The message was valid JSON but did not match the expected framing;
 `reason` describes the mismatch.

##### `MissingField(name: String)`

A required field was absent; `name` is the missing field.

### `Frame`

Encoded WebSocket frame returned by a codec.

```gleam
pub type Frame {
  TextFrame(String)
  BinaryFrame(BitArray)
}
```

#### Constructors

##### `TextFrame(String)`

A UTF-8 text frame.

##### `BinaryFrame(BitArray)`

A binary frame.

### `Inbound`

Normalised inbound message shape.

 - `join_ref`: optional client-side reference assigned at join time
   (used by some Phoenix replies; codecs without this concept should
   pass `None`)
 - `ref`: optional per-message reference for reply correlation
 - `topic`: subscription topic (e.g. `"room:lobby"`, `"doc:abc"`)
 - `kind`: structural protocol event or user event
 - `payload`: message body as a `Dynamic` for the channel handler to
   decode

```gleam
pub type Inbound {
  Inbound(
    join_ref: option.Option(String),
    ref: option.Option(String),
    topic: String,
    kind: InboundKind,
    payload: dynamic.Dynamic
  )
}
```

### `InboundKind`

Structural inbound message kind used for protocol dispatch.

```gleam
pub type InboundKind {
  Join
  Leave
  Heartbeat
  Event(String)
}
```

#### Constructors

##### `Join`

A client joining a topic.

##### `Leave`

A client leaving a topic.

##### `Heartbeat`

A heartbeat/keep-alive message.

##### `Event(String)`

A user-defined event; the wrapped `String` is the event name.

### `ReplyStatus`

Status of a reply produced by a channel handler.

```gleam
pub type ReplyStatus {
  StatusOk
  StatusError
}
```

#### Constructors

##### `StatusOk`

The handler succeeded (`"ok"` in Phoenix framing).

##### `StatusError`

The handler failed (`"error"` in Phoenix framing).

## Functions

### `format_decode_error`

Format a `DecodeError` as a human-readable string. Used by the
 coordinator's log messages and by `wire.format_decode_error`.

```gleam
pub fn format_decode_error(DecodeError) -> String
```
