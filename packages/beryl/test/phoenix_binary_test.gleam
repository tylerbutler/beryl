//// Phoenix V2 binary framing tests: byte-exact spec vectors for the
//// encoders/decoder. End-to-end binary dispatch through the app runtime is
//// covered by `app_binary_codec_test`.

import beryl/wire
import beryl/wire/codec
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// === Decoder spec vectors ===

pub fn decode_binary_client_push_test() -> Nil {
  // <<push=0, jr_len=2, ref_len=2, topic_len=10, event_len=4,
  //   "j1", "r1", "room:lobby", "ping", payload...>>
  let frame = <<
    0,
    2,
    2,
    10,
    4,
    "j1":utf8,
    "r1":utf8,
    "room:lobby":utf8,
    "ping":utf8,
    1,
    2,
    3,
  >>

  let assert Ok(inbound) = wire.decode_binary_message(frame)
  codec.inbound_join_ref(inbound) |> should.equal(Some("j1"))
  codec.inbound_ref(inbound) |> should.equal(Some("r1"))
  codec.inbound_topic(inbound) |> should.equal("room:lobby")
  codec.inbound_kind(inbound) |> should.equal(codec.Event("ping"))

  let assert Ok(payload) =
    decode.run(codec.inbound_payload(inbound), decode.bit_array)
  payload |> should.equal(<<1, 2, 3>>)
}

pub fn decode_binary_zero_length_refs_are_none_test() -> Nil {
  let frame = <<0, 0, 0, 3, 3, "t:1":utf8, "evt":utf8>>

  let assert Ok(inbound) = wire.decode_binary_message(frame)
  codec.inbound_join_ref(inbound) |> should.equal(None)
  codec.inbound_ref(inbound) |> should.equal(None)

  // Empty payload survives as empty bytes.
  let assert Ok(payload) =
    decode.run(codec.inbound_payload(inbound), decode.bit_array)
  payload |> should.equal(<<>>)
}

pub fn decode_binary_classifies_reserved_events_test() -> Nil {
  let join = <<
    0,
    2,
    2,
    6,
    8,
    "j1":utf8,
    "r1":utf8,
    "room:a":utf8,
    "phx_join":utf8,
  >>
  let assert Ok(inbound) = wire.decode_binary_message(join)
  codec.inbound_kind(inbound) |> should.equal(codec.Join)
}

pub fn decode_binary_rejects_truncated_frame_test() -> Nil {
  // Declares a 10-byte topic but the frame ends early.
  let truncated = <<0, 0, 0, 10, 4, "sho":utf8>>
  let assert Error(codec.InvalidFormat(_)) =
    wire.decode_binary_message(truncated)

  // Wrong kind byte (only client pushes are decodable server-side).
  let wrong_kind = <<2, 3, 4, "abc":utf8, "defg":utf8>>
  let assert Error(codec.InvalidFormat(_)) =
    wire.decode_binary_message(wrong_kind)
  Nil
}

pub fn decode_binary_names_invalid_join_ref_utf8_test() -> Nil {
  let frame = <<0, 1, 2, 3, 3, 255, "r1":utf8, "t:1":utf8, "evt":utf8>>

  wire.decode_binary_message(frame)
  |> should.equal(Error(codec.InvalidFormat("join_ref is not valid UTF-8")))
}

pub fn decode_binary_names_invalid_ref_utf8_test() -> Nil {
  let frame = <<0, 2, 1, 3, 3, "j1":utf8, 255, "t:1":utf8, "evt":utf8>>

  wire.decode_binary_message(frame)
  |> should.equal(Error(codec.InvalidFormat("ref is not valid UTF-8")))
}

// === Encoder spec vectors ===

pub fn binary_push_encodes_spec_shape_test() -> Nil {
  let assert Ok(codec.BinaryFrame(frame)) =
    wire.binary_push(
      join_ref: Some("j1"),
      topic: "room:lobby",
      event: "tick",
      payload: <<9, 8>>,
    )
  frame
  |> should.equal(<<
    0,
    2,
    10,
    4,
    "j1":utf8,
    "room:lobby":utf8,
    "tick":utf8,
    9,
    8,
  >>)
}

pub fn binary_reply_encodes_spec_shape_test() -> Nil {
  let assert Ok(codec.BinaryFrame(frame)) =
    wire.binary_reply(
      join_ref: Some("j1"),
      ref: Some("r7"),
      topic: "room:a",
      status: codec.StatusOk,
      payload: <<1>>,
    )
  frame
  |> should.equal(<<
    1,
    2,
    2,
    6,
    2,
    "j1":utf8,
    "r7":utf8,
    "room:a":utf8,
    "ok":utf8,
    1,
  >>)
}

pub fn binary_broadcast_encodes_spec_shape_test() -> Nil {
  let assert Ok(codec.BinaryFrame(frame)) =
    wire.binary_broadcast(topic: "room:a", event: "tick", payload: <<7>>)
  frame
  |> should.equal(<<2, 6, 4, "room:a":utf8, "tick":utf8, 7>>)
}

pub fn binary_encoders_reject_oversized_components_test() -> Nil {
  let long = string.repeat("a", 256)
  list.each([<<>>, <<1:size(1)>>], fn(payload) {
    wire.binary_push(join_ref: None, topic: long, event: "e", payload: payload)
    |> should.equal(Error(wire.MetadataTooLong("topic", 256)))
    wire.binary_reply(
      join_ref: None,
      ref: Some(long),
      topic: "t",
      status: codec.StatusOk,
      payload: payload,
    )
    |> should.equal(Error(wire.MetadataTooLong("ref", 256)))
    wire.binary_broadcast(topic: "t", event: long, payload: payload)
    |> should.equal(Error(wire.MetadataTooLong("event", 256)))
  })
}

pub fn binary_encoders_reject_partial_byte_payloads_test() -> Nil {
  list.each([1, 7, 9, 15], fn(size) {
    let payload = <<1:size(size)>>
    wire.binary_push(None, "t", "e", payload)
    |> should.equal(Error(wire.PayloadNotByteAligned))
    wire.binary_reply(None, None, "t", codec.StatusOk, payload)
    |> should.equal(Error(wire.PayloadNotByteAligned))
    wire.binary_broadcast("t", "e", payload)
    |> should.equal(Error(wire.PayloadNotByteAligned))
  })
}

pub fn binary_encoders_preserve_empty_payloads_test() -> Nil {
  wire.binary_push(None, "t", "e", <<>>)
  |> should.equal(Ok(codec.BinaryFrame(<<0, 0, 1, 1, "te":utf8>>)))
  wire.binary_reply(None, None, "t", codec.StatusOk, <<>>)
  |> should.equal(Ok(codec.BinaryFrame(<<1, 0, 0, 1, 2, "tok":utf8>>)))
  wire.binary_broadcast("t", "e", <<>>)
  |> should.equal(Ok(codec.BinaryFrame(<<2, 1, 1, "te":utf8>>)))
}
