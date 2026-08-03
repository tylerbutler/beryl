---
title: "beryl/wire"
description: "Phoenix Wire Protocol — encoding/decoding helpers and the canonical"
---

Phoenix Wire Protocol — encoding/decoding helpers and the canonical
 `phoenix_codec()` for `beryl/wire/codec`.

 Phoenix uses a JSON array format: `[join_ref, ref, topic, event, payload]`.
 This module parses and emits that format, and exposes a `Codec` value
 that plugs the Phoenix framing into the runtime.

 To use Phoenix framing (the historical default) construct beryl with:

 ```gleam
 beryl.config(wire.phoenix_codec())
 ```

## Functions

### `binary_broadcast`

Encode a Phoenix V2 binary broadcast: `(topic, event, payload)`.

 Errors when a metadata component exceeds the framing's 255-byte length
 limit.

```gleam
pub fn binary_broadcast(
  topic: String,
  event: String,
  payload: BitArray
) -> Result(codec.Frame, Nil)
```

### `binary_push`

Encode a Phoenix V2 binary server push: `(join_ref, topic, event, payload)`.

 Errors when a metadata component exceeds the framing's 255-byte length
 limit.

```gleam
pub fn binary_push(
  join_ref: option.Option(String),
  topic: String,
  event: String,
  payload: BitArray
) -> Result(codec.Frame, Nil)
```

### `binary_reply`

Encode a Phoenix V2 binary reply: `(join_ref, ref, topic, status, payload)`.

 Errors when a metadata component exceeds the framing's 255-byte length
 limit.

```gleam
pub fn binary_reply(
  join_ref: option.Option(String),
  ref: option.Option(String),
  topic: String,
  status: codec.ReplyStatus,
  payload: BitArray
) -> Result(codec.Frame, Nil)
```

### `channel_close`

Create a Phoenix `phx_close` frame, sent when a channel terminates
 gracefully. Phoenix mirrors the channel's `join_ref` into the `ref` slot.

```gleam
pub fn channel_close(
  option.Option(String),
  String
) -> codec.Frame
```

### `channel_error`

Create a Phoenix `phx_error` frame, sent when a channel terminates
 abnormally. Phoenix clients respond by scheduling an automatic rejoin.

```gleam
pub fn channel_error(
  option.Option(String),
  String
) -> codec.Frame
```

### `decode_binary_message`

Decode a Phoenix V2 binary push frame from a client into an `Inbound`.

 The payload is delivered to the app's `update` as a `Binary` event
 (raw bytes as `BitArray` wrapped in `Dynamic` at the wire layer); decode
 it with `gleam/dynamic/decode.bit_array` if needed. Zero-length
 join_ref/ref components decode as `None`. Reserved protocol events are
 classified the same way as on the text framing.

```gleam
pub fn decode_binary_message(BitArray) -> Result(codec.Inbound, codec.DecodeError)
```

### `decode_message`

Parse a JSON string into an `Inbound`.

 Expected format: `[join_ref, ref, topic, event, payload]` where
 `join_ref` and `ref` may be `null`.

```gleam
pub fn decode_message(String) -> Result(codec.Inbound, codec.DecodeError)
```

### `dynamic_to_json`

Convert a `Dynamic` (decoded from JSON) back into `json.Json`.

```gleam
pub fn dynamic_to_json(dynamic.Dynamic) -> json.Json
```

### `encode`

Encode an `Inbound` back to a Phoenix wire JSON string.

```gleam
pub fn encode(codec.Inbound) -> String
```

### `format_decode_error`

Format a `DecodeError` as a human-readable string.

```gleam
pub fn format_decode_error(codec.DecodeError) -> String
```

### `heartbeat_reply`

Create a Phoenix heartbeat reply.

```gleam
pub fn heartbeat_reply(option.Option(String)) -> codec.Frame
```

### `phoenix_codec`

The canonical Phoenix wire codec. Pass to `beryl.config/1`.

 Handles both the JSON array framing on text frames and the Phoenix V2
 binary framing on binary frames (see `decode_binary_message`). Binary
 push payloads reach the app's `update` as a `Binary` event (raw bytes as
 `BitArray` wrapped in `Dynamic` at the wire layer); decode with
 `gleam/dynamic/decode.bit_array` if needed.

```gleam
pub fn phoenix_codec() -> codec.Codec
```

### `push`

Create a server-initiated push message.

```gleam
pub fn push(
  String,
  String,
  json.Json
) -> codec.Frame
```

### `reply_json`

Create a Phoenix `phx_reply` JSON string.

```gleam
pub fn reply_json(
  option.Option(String),
  option.Option(String),
  String,
  codec.ReplyStatus,
  json.Json
) -> codec.Frame
```
