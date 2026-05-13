//// Tests for the pluggable wire codec abstraction.

import beryl/wire
import beryl/wire/codec
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import phoenix_channel_fixtures/frame as fixtures

// === Phoenix codec ===

pub fn phoenix_codec_round_trip_test() {
  let phoenix = wire.phoenix_codec()
  let encoded = phoenix.encode_push("room:1", "msg", json.string("hi"))
  let assert Ok(inbound) = phoenix.decode(encoded)
  inbound.topic |> should.equal("room:1")
  inbound.event |> should.equal("msg")
}

pub fn phoenix_codec_uses_phoenix_event_names_test() {
  let phoenix = wire.phoenix_codec()
  phoenix.join_event |> should.equal("phx_join")
  phoenix.leave_event |> should.equal("phx_leave")
  phoenix.heartbeat_event |> should.equal("heartbeat")
}

// === Custom codec that swaps event names ===

/// Build a tiny test codec that uses different system event names. We
/// reuse the Phoenix wire format for encoding/decoding and only override
/// the event names — that is enough to prove the coordinator dispatches
/// based on the codec, not on hardcoded constants.
fn fake_codec() -> codec.Codec {
  let phoenix = wire.phoenix_codec()
  codec.Codec(
    ..phoenix,
    join_event: "JOIN",
    leave_event: "LEAVE",
    heartbeat_event: "PING",
  )
}

pub fn custom_codec_keeps_phoenix_decode_test() {
  let custom = fake_codec()
  // Build a Phoenix-format frame with our custom join_event name as the
  // event field; the codec must still decode it (it shares the format).
  let raw = "[null,\"r1\",\"room:1\",\"JOIN\",{}]"
  let assert Ok(inbound) = custom.decode(raw)
  inbound.event |> should.equal("JOIN")
  inbound.event |> should.equal(custom.join_event)
}

pub fn custom_codec_distinct_from_phoenix_test() {
  let custom = fake_codec()
  let phoenix = wire.phoenix_codec()
  custom.join_event |> should.not_equal(phoenix.join_event)
}

// === Inbound shape ===

pub fn inbound_record_holds_normalized_fields_test() {
  let payload = dynamic.string("body")
  let inbound =
    codec.Inbound(
      join_ref: Some("j"),
      ref: Some("r"),
      topic: "room:1",
      event: "evt",
      payload: payload,
    )
  inbound.topic |> should.equal("room:1")
  inbound.join_ref |> should.equal(Some("j"))
}

pub fn inbound_supports_optional_refs_test() {
  let inbound =
    codec.Inbound(
      join_ref: None,
      ref: None,
      topic: "t",
      event: "e",
      payload: dynamic.nil(),
    )
  inbound.ref |> should.equal(None)
}

// === Reply status ===

pub fn reply_status_round_trips_through_phoenix_codec_test() {
  let phoenix = wire.phoenix_codec()
  let s =
    phoenix.encode_reply(
      Some("j"),
      "r",
      "topic:1",
      codec.StatusOk,
      json.object([#("k", json.string("v"))]),
    )
  // Sanity: it produced *something* recognisable as a Phoenix reply.
  s
  |> wire.decode_message()
  |> should.be_ok()
}

pub fn phoenix_codec_decodes_shared_inbound_fixtures_test() {
  let phoenix = wire.phoenix_codec()
  fixtures.inbound_common()
  |> list.each(fn(case_) {
    let assert Ok(inbound) = phoenix.decode(case_.encoded)
    inbound.join_ref |> should.equal(case_.join_ref)
    inbound.ref |> should.equal(case_.ref)
    inbound.topic |> should.equal(case_.topic)
    inbound.event |> should.equal(case_.event)
    let assert Ok(expected_payload) =
      json.parse(from: json.to_string(case_.payload), using: decode.dynamic)
    inbound.payload |> should.equal(expected_payload)
  })
}

pub fn phoenix_codec_encodes_shared_server_push_fixtures_test() {
  let phoenix = wire.phoenix_codec()
  fixtures.server_outbound()
  |> list.each(fn(case_) {
    case case_.ref, case_.event, case_.topic {
      None, event, topic
        if topic != fixtures.heartbeat_topic
        && event != fixtures.error_event
        && event != fixtures.close_event
      ->
        phoenix.encode_push(case_.topic, event, case_.payload)
        |> should.equal(case_.encoded)
      _, _, _ -> Nil
    }
  })
}

pub fn phoenix_codec_encodes_shared_reply_fixtures_test() {
  let phoenix = wire.phoenix_codec()
  fixtures.replies()
  |> list.each(fn(case_) {
    let status = case case_.status {
      fixtures.StatusOk -> codec.StatusOk
      fixtures.StatusError -> codec.StatusError
    }
    phoenix.encode_reply(
      case_.join_ref,
      case_.ref,
      case_.topic,
      status,
      case_.response,
    )
    |> should.equal(case_.encoded)
  })
}

pub fn phoenix_codec_rejects_shared_invalid_fixtures_test() {
  let phoenix = wire.phoenix_codec()
  fixtures.invalid_frames()
  |> list.each(fn(case_) {
    case case_.reason {
      fixtures.InvalidJson -> {
        let assert Error(codec.InvalidJson(_)) = phoenix.decode(case_.encoded)
        Nil
      }
      fixtures.InvalidFormat -> {
        let assert Error(codec.InvalidFormat(_)) = phoenix.decode(case_.encoded)
        Nil
      }
    }
  })
}
