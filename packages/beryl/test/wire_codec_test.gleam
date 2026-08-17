//// Tests for the pluggable wire codec abstraction.

import beryl/wire
import beryl/wire/codec
import envoy
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import phoenix_channel_fixtures/frame as fixtures

const phoenix_codec_env = "BERYL_PHOENIX_CODEC"

// === Phoenix codec ===

pub fn phoenix_codec_round_trip_test() {
  let phoenix = wire.phoenix_codec()
  let encoded =
    text_frame(codec.encode_push(phoenix)("room:1", "msg", json.string("hi")))
  let assert Ok(inbound) = codec.decode_text(phoenix)(encoded)
  codec.inbound_topic(inbound) |> should.equal("room:1")
  codec.inbound_kind(inbound) |> should.equal(codec.Event("msg"))
}

pub fn phoenix_codec_decodes_system_events_to_kinds_test() {
  let phoenix = wire.phoenix_codec()

  let assert Ok(join) =
    codec.decode_text(phoenix)("[\"j\",\"r\",\"room:1\",\"phx_join\",{}]")
  codec.inbound_kind(join) |> should.equal(codec.Join)

  let assert Ok(leave) =
    codec.decode_text(phoenix)("[null,\"r\",\"room:1\",\"phx_leave\",{}]")
  codec.inbound_kind(leave) |> should.equal(codec.Leave)

  let assert Ok(heartbeat) =
    codec.decode_text(phoenix)("[null,\"r\",\"phoenix\",\"heartbeat\",{}]")
  codec.inbound_kind(heartbeat) |> should.equal(codec.Heartbeat)

  // "heartbeat" is only reserved on the "phoenix" topic; elsewhere it is an
  // ordinary application event that must reach the app's `update` function.
  let assert Ok(app_heartbeat) =
    codec.decode_text(phoenix)("[null,\"r\",\"room:1\",\"heartbeat\",{}]")
  codec.inbound_kind(app_heartbeat) |> should.equal(codec.Event("heartbeat"))

  let assert Ok(event) =
    codec.decode_text(phoenix)("[null,\"r\",\"room:1\",\"new_msg\",{}]")
  codec.inbound_kind(event) |> should.equal(codec.Event("new_msg"))
}

pub fn phoenix_codec_reply_accepts_missing_ref_test() {
  let phoenix = wire.phoenix_codec()

  let frame =
    codec.encode_reply(phoenix)(
      None,
      None,
      "room:1",
      codec.StatusOk,
      json.object([]),
    )

  let assert codec.TextFrame(encoded) = frame
  encoded
  |> should.equal(
    "[null,null,\"room:1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  )
}

pub fn phoenix_codec_defaults_to_native_implementation_test() {
  with_env_value(phoenix_codec_env, None, fn() {
    let phoenix = wire.phoenix_codec()

    let assert Error(codec.InvalidFormat(reason)) =
      codec.decode_text(phoenix)("[null,\"1\",123,\"event\",{}]")

    reason
    |> should.equal("Expected String at index 2, found Int")
  })
}

pub fn phoenix_codec_uses_native_when_env_is_unknown_test() {
  with_env_value(phoenix_codec_env, Some("native"), fn() {
    let phoenix = wire.phoenix_codec()

    let assert Error(codec.InvalidFormat(reason)) =
      codec.decode_text(phoenix)("[null,\"1\",123,\"event\",{}]")

    reason
    |> should.equal("Expected String at index 2, found Int")
  })
}

pub fn phoenix_codec_preserves_missing_ref_reply_shape_test() {
  let phoenix = wire.phoenix_codec()

  codec.encode_reply(phoenix)(
    Some("join-ref"),
    None,
    "room:1",
    codec.StatusOk,
    json.object([]),
  )
  |> text_frame()
  |> should.equal(
    "[\"join-ref\",null,\"room:1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  )
}

// === Inbound shape ===

pub fn inbound_record_holds_normalized_fields_test() {
  let payload = dynamic.string("body")
  let inbound =
    codec.inbound(
      join_ref: Some("j"),
      ref: Some("r"),
      topic: "room:1",
      kind: codec.Event("evt"),
      payload: payload,
    )
  codec.inbound_topic(inbound) |> should.equal("room:1")
  codec.inbound_join_ref(inbound) |> should.equal(Some("j"))
}

pub fn inbound_supports_optional_refs_test() {
  let inbound =
    codec.inbound(
      join_ref: None,
      ref: None,
      topic: "t",
      kind: codec.Event("e"),
      payload: dynamic.nil(),
    )
  codec.inbound_ref(inbound) |> should.equal(None)
}

pub fn public_codec_operations_apply_configured_behaviour_test() {
  let base =
    codec.new(
      decode_text: fn(text) {
        Ok(codec.inbound(
          join_ref: None,
          ref: None,
          topic: "text",
          kind: codec.Event(text),
          payload: dynamic.nil(),
        ))
      },
      encode_reply: fn(_, _, _, _, _) { codec.TextFrame("reply") },
      encode_push: fn(topic, event, _) {
        codec.TextFrame(topic <> ":" <> event)
      },
      encode_heartbeat_reply: fn(_) { codec.TextFrame("heartbeat") },
    )

  let assert Ok(text_inbound) = codec.apply_decode_text(base, text: "decoded")
  codec.inbound_kind(text_inbound) |> should.equal(codec.Event("decoded"))
  codec.apply_decode_binary(base, data: <<1>>) |> should.equal(None)
  codec.apply_encode_reply(
    base,
    join_ref: None,
    ref: None,
    topic: "room:1",
    status: codec.StatusOk,
    response: json.null(),
  )
  |> should.equal(codec.TextFrame("reply"))
  codec.apply_encode_push(
    base,
    topic: "room:1",
    event: "updated",
    payload: json.null(),
  )
  |> should.equal(codec.TextFrame("room:1:updated"))
  codec.apply_encode_heartbeat_reply(base, ref: None)
  |> should.equal(codec.TextFrame("heartbeat"))
  codec.apply_encode_close(base, join_ref: None, topic: "room:1")
  |> should.equal(None)
  codec.apply_encode_error(base, join_ref: None, topic: "room:1")
  |> should.equal(None)
  codec.uses_topicless_events(base) |> should.be_false()

  let configured =
    base
    |> codec.with_binary_decoder(fn(_) {
      Ok(codec.inbound(
        join_ref: None,
        ref: None,
        topic: "binary",
        kind: codec.Event("decoded"),
        payload: dynamic.nil(),
      ))
    })
    |> codec.with_close_encoder(fn(_, topic) {
      codec.TextFrame("close:" <> topic)
    })
    |> codec.with_error_encoder(fn(_, topic) {
      codec.TextFrame("error:" <> topic)
    })
    |> codec.with_topicless_events()

  let assert Some(Ok(binary_inbound)) =
    codec.apply_decode_binary(configured, data: <<1>>)
  codec.inbound_topic(binary_inbound) |> should.equal("binary")
  codec.apply_encode_close(configured, join_ref: None, topic: "room:1")
  |> should.equal(Some(codec.TextFrame("close:room:1")))
  codec.apply_encode_error(configured, join_ref: None, topic: "room:1")
  |> should.equal(Some(codec.TextFrame("error:room:1")))
  codec.uses_topicless_events(configured) |> should.be_true()
}

pub fn dynamic_to_json_decodes_nested_json_values_test() {
  let encoded = "[\"text\",1,1.5,true,null,{\"nested\":[false]}]"
  let assert Ok(dynamic_value) =
    json.parse(from: encoded, using: decode.dynamic)
  let assert Ok(json_value) = wire.dynamic_to_json(dynamic_value)

  json.to_string(json_value) |> should.equal(encoded)
}

// === Reply status ===

pub fn reply_status_round_trips_through_phoenix_codec_test() {
  let phoenix = wire.phoenix_codec()
  let s =
    codec.encode_reply(phoenix)(
      Some("j"),
      Some("r"),
      "topic:1",
      codec.StatusOk,
      json.object([#("k", json.string("v"))]),
    )
  // Sanity: it produced *something* recognisable as a Phoenix reply.
  text_frame(s)
  |> wire.decode_message()
  |> should.be_ok()
}

pub fn phoenix_codec_decodes_shared_inbound_fixtures_test() {
  let phoenix = wire.phoenix_codec()
  fixtures.inbound_common()
  |> list.each(fn(case_) {
    let assert Ok(inbound) = codec.decode_text(phoenix)(case_.encoded)
    codec.inbound_join_ref(inbound) |> should.equal(case_.join_ref)
    codec.inbound_ref(inbound) |> should.equal(case_.ref)
    codec.inbound_topic(inbound) |> should.equal(case_.topic)
    codec.inbound_kind(inbound) |> should.equal(phoenix_kind(case_.event))
    let assert Ok(expected_payload) =
      json.parse(from: json.to_string(case_.payload), using: decode.dynamic)
    codec.inbound_payload(inbound) |> should.equal(expected_payload)
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
        codec.encode_push(phoenix)(case_.topic, event, case_.payload)
        |> text_frame()
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
    codec.encode_reply(phoenix)(
      case_.join_ref,
      Some(case_.ref),
      case_.topic,
      status,
      case_.response,
    )
    |> text_frame()
    |> should.equal(case_.encoded)
  })
}

pub fn phoenix_codec_encodes_shared_terminal_event_fixtures_test() {
  let phoenix = wire.phoenix_codec()
  let assert Some(encode_close) = codec.encode_close(phoenix)
  let assert Some(encode_error) = codec.encode_error(phoenix)
  fixtures.server_outbound()
  |> list.each(fn(case_) {
    case case_.event {
      "phx_error" ->
        encode_error(case_.join_ref, case_.topic)
        |> text_frame()
        |> should.equal(case_.encoded)
      "phx_close" ->
        encode_close(case_.join_ref, case_.topic)
        |> text_frame()
        |> should.equal(case_.encoded)
      _ -> Nil
    }
  })
}

pub fn phoenix_terminal_events_mirror_join_ref_into_ref_test() {
  wire.channel_close(Some("join-7"), "room:1")
  |> text_frame()
  |> should.equal("[\"join-7\",\"join-7\",\"room:1\",\"phx_close\",{}]")

  wire.channel_error(Some("join-7"), "room:1")
  |> text_frame()
  |> should.equal("[\"join-7\",\"join-7\",\"room:1\",\"phx_error\",{}]")
}

pub fn phoenix_codec_rejects_shared_invalid_fixtures_test() {
  let phoenix = wire.phoenix_codec()
  fixtures.invalid_frames()
  |> list.each(fn(case_) {
    case case_.reason {
      fixtures.InvalidJson -> {
        let assert Error(codec.InvalidJson(_)) =
          codec.decode_text(phoenix)(case_.encoded)
        Nil
      }
      fixtures.InvalidFormat -> {
        let assert Error(codec.InvalidFormat(_)) =
          codec.decode_text(phoenix)(case_.encoded)
        Nil
      }
    }
  })
}

pub fn phoenix_codec_rejects_excessively_nested_payload_test() {
  let phoenix = wire.phoenix_codec()
  let nested_payload =
    string.repeat("[", 70) <> "null" <> string.repeat("]", 70)

  let assert Error(codec.InvalidFormat(reason)) =
    codec.decode_text(phoenix)(
      "[null,\"r\",\"room:1\",\"event\"," <> nested_payload <> "]",
    )

  reason |> string.contains("JSON nesting depth") |> should.be_true
}

fn text_frame(frame: codec.Frame) -> String {
  let assert codec.TextFrame(text) = frame
  text
}

fn with_env_value(name: String, value: Option(String), run: fn() -> a) -> a {
  let previous = envoy.get(name)
  case value {
    Some(value) -> envoy.set(name, value)
    None -> envoy.unset(name)
  }

  let result = run()

  case previous {
    Ok(value) -> envoy.set(name, value)
    Error(Nil) -> envoy.unset(name)
  }

  result
}

fn phoenix_kind(event: String) -> codec.InboundKind {
  case event {
    "phx_join" -> codec.Join
    "phx_leave" -> codec.Leave
    "heartbeat" -> codec.Heartbeat
    other -> codec.Event(other)
  }
}
