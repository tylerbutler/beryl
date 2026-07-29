//// Phoenix V2 binary framing tests: byte-exact spec vectors for the
//// encoders/decoder, plus end-to-end dispatch through the coordinator.

import beryl
import beryl/channel
import beryl/coordinator
import beryl/internal/unsupervised
import beryl/wire
import beryl/wire/codec
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// === Decoder spec vectors ===

pub fn decode_binary_client_push_test() {
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

pub fn decode_binary_zero_length_refs_are_none_test() {
  let frame = <<0, 0, 0, 3, 3, "t:1":utf8, "evt":utf8>>

  let assert Ok(inbound) = wire.decode_binary_message(frame)
  codec.inbound_join_ref(inbound) |> should.equal(None)
  codec.inbound_ref(inbound) |> should.equal(None)

  // Empty payload survives as empty bytes.
  let assert Ok(payload) =
    decode.run(codec.inbound_payload(inbound), decode.bit_array)
  payload |> should.equal(<<>>)
}

pub fn decode_binary_classifies_reserved_events_test() {
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

pub fn decode_binary_rejects_truncated_frame_test() {
  // Declares a 10-byte topic but the frame ends early.
  let truncated = <<0, 0, 0, 10, 4, "sho":utf8>>
  let assert Error(codec.InvalidFormat(_)) =
    wire.decode_binary_message(truncated)

  // Wrong kind byte (only client pushes are decodable server-side).
  let wrong_kind = <<2, 3, 4, "abc":utf8, "defg":utf8>>
  let assert Error(codec.InvalidFormat(_)) =
    wire.decode_binary_message(wrong_kind)
}

// === Encoder spec vectors ===

pub fn binary_push_encodes_spec_shape_test() {
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

pub fn binary_reply_encodes_spec_shape_test() {
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

pub fn binary_broadcast_encodes_spec_shape_test() {
  let assert Ok(codec.BinaryFrame(frame)) =
    wire.binary_broadcast(topic: "room:a", event: "tick", payload: <<7>>)
  frame
  |> should.equal(<<2, 6, 4, "room:a":utf8, "tick":utf8, 7>>)
}

pub fn binary_encoders_reject_oversized_components_test() {
  let long = string.repeat("a", 256)
  wire.binary_push(join_ref: None, topic: long, event: "e", payload: <<>>)
  |> should.be_error
  wire.binary_broadcast(topic: "t", event: long, payload: <<>>)
  |> should.be_error
}

// === End-to-end through the coordinator ===

pub fn phoenix_binary_push_routes_to_handle_in_with_reply_test() {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let seen = process.new_subject()

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
    |> channel.with_handle_in(fn(event, payload, socket) {
      let assert Ok(bits) = channel.decode_payload(payload, decode.bit_array)
      process.send(seen, #(event, bits))
      channel.Reply(event: "ok", payload: json.object([]), socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  let sent = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-1",
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  process.sleep(10)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[\"j1\",\"j1\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_join_reply) = process.receive(sent, 500)

  // Client binary push: routed to the joined channel, not fanned out raw.
  coordinator.route_binary(beryl.coordinator_subject(channels), "socket-1", <<
    0,
    2,
    2,
    10,
    6,
    "j1":utf8,
    "r9":utf8,
    "room:lobby":utf8,
    "put_op":utf8,
    42,
    43,
  >>)

  let assert Ok(#(event, bits)) = process.receive(seen, 500)
  event |> should.equal("put_op")
  bits |> should.equal(<<42, 43>>)

  // The reply correlates with the binary push's ref and join_ref.
  let assert Ok(reply) = process.receive(sent, 500)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("r9") |> should.be_true
  reply |> string.contains("j1") |> should.be_true
}

pub fn phoenix_malformed_binary_frame_is_dropped_test() {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let seen_binary = process.new_subject()

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
    |> channel.with_handle_binary(fn(data, socket) {
      process.send(seen_binary, data)
      channel.NoReply(socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  let sent = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-1",
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  process.sleep(10)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[\"j1\",\"j1\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_join_reply) = process.receive(sent, 500)

  // Undecodable bytes are dropped for the Phoenix codec — they no longer
  // fan out raw to handle_binary.
  coordinator.route_binary(beryl.coordinator_subject(channels), "socket-1", <<
    255,
    1,
    2,
    3,
  >>)
  process.receive(seen_binary, 100) |> should.be_error
}
