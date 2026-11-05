# Codec interface

## Overview

The public `beryl/wire/codec` module defines the normalized frame and callback
contract between wire encodings, the runtime, and transports. The parent
`beryl/wire` module supplies the Phoenix implementation.

## Interface

- `Frame`, `InboundKind`, `DecodeError`, and `ReplyStatus` describe outbound
  frames, inbound lifecycle events, and failures (`codec.gleam:Frame`,
  `codec.gleam:InboundKind`, `codec.gleam:DecodeError`,
  `codec.gleam:ReplyStatus`).
- `inbound` constructs opaque `Inbound`; `inbound_join_ref`, `inbound_ref`,
  `inbound_topic`, `inbound_kind`, and `inbound_payload` inspect it
  (`codec.gleam:inbound`, `codec.gleam:inbound_join_ref`,
  `codec.gleam:inbound_payload`).
- `new` constructs opaque `Codec` with required text decoder and reply/push/
  heartbeat encoders. Builders add binary decoding, close/error encoding, and
  topicless-event support (`codec.gleam:new`, `codec.gleam:with_binary_decoder`,
  `codec.gleam:with_close_encoder`, `codec.gleam:with_error_encoder`,
  `codec.gleam:with_topicless_events`).
- Public `apply_decode_*` and `apply_encode_*` functions invoke configured
  callbacks; `uses_topicless_events` reports the flag and `format_decode_error`
  formats errors (`codec.gleam:apply_decode_text`,
  `codec.gleam:apply_decode_binary`, `codec.gleam:apply_encode_reply`,
  `codec.gleam:apply_encode_push`, `codec.gleam:apply_encode_heartbeat_reply`,
  `codec.gleam:apply_encode_close`, `codec.gleam:apply_encode_error`,
  `codec.gleam:uses_topicless_events`, `codec.gleam:format_decode_error`).
- Callback accessors such as `decode_text` and `encode_reply` have `@internal`
  visibility (`codec.gleam:decode_text`, `codec.gleam:encode_reply`).

## Invariants

- New codecs have no binary decoder or terminal encoders and disable topicless
  events. Without a binary decoder, the runtime can deliver raw `Binary` input
  (`codec.gleam:new`, `codec.gleam:with_binary_decoder`).
- Missing close/error encoders produce `None`
  (`codec.gleam:apply_encode_close`, `codec.gleam:apply_encode_error`).
- Topicless routing requires the flag and exactly one joined topic. Codecs that
  include topics should leave the flag disabled
  (`codec.gleam:with_topicless_events`).

## Side effects

This module stores and invokes caller-supplied callbacks; it performs no
transport I/O itself. Callback effects belong to the supplied implementation
(`codec.gleam:apply_decode_text`, `codec.gleam:apply_encode_reply`).

## Verification

From the repository root: `just test beryl`.
