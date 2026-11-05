//// Tests for the pluggable wire codec abstraction.

import beryl/wire
import beryl/wire/codec
import envoy
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import phoenix_channel_fixtures/frame as fixtures

const phoenix_codec_env = "BERYL_PHOENIX_CODEC"

// === Phoenix codec ===

pub fn phoenix_codec_round_trip_test() -> Nil {
  let phoenix = wire.phoenix_codec()
  let encoded =
    encoded_text_frame(codec.encode_push(phoenix)(
      "room:1",
      "message",
      json.string("hi"),
    ))
  let assert Ok(inbound) = codec.decode_text(phoenix)(encoded)
  codec.inbound_topic(inbound) |> should.equal("room:1")
  codec.inbound_kind(inbound) |> should.equal(codec.Event("message"))
}

pub fn phoenix_codec_decodes_system_events_to_kinds_test() -> Nil {
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

pub fn phoenix_codec_reply_accepts_missing_ref_test() -> Nil {
  let phoenix = wire.phoenix_codec()

  let frame =
    codec.encode_reply(phoenix)(
      None,
      None,
      "room:1",
      codec.StatusOk,
      json.object([]),
    )

  let assert Ok(codec.TextFrame(encoded)) = frame
  encoded
  |> should.equal(
    "[null,null,\"room:1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  )
}

pub fn phoenix_codec_defaults_to_native_implementation_test() -> Nil {
  with_env_value(phoenix_codec_env, None, fn() {
    let phoenix = wire.phoenix_codec()

    let assert Error(codec.InvalidFormat(reason)) =
      codec.decode_text(phoenix)("[null,\"1\",123,\"event\",{}]")

    reason
    |> should.equal("Expected String at index 2, found Int")
  })
}

pub fn phoenix_codec_uses_native_when_env_is_unknown_test() -> Nil {
  with_env_value(phoenix_codec_env, Some("native"), fn() {
    let phoenix = wire.phoenix_codec()

    let assert Error(codec.InvalidFormat(reason)) =
      codec.decode_text(phoenix)("[null,\"1\",123,\"event\",{}]")

    reason
    |> should.equal("Expected String at index 2, found Int")
  })
}

pub fn phoenix_codec_preserves_missing_ref_reply_shape_test() -> Nil {
  let phoenix = wire.phoenix_codec()

  codec.encode_reply(phoenix)(
    Some("join-ref"),
    None,
    "room:1",
    codec.StatusOk,
    json.object([]),
  )
  |> encoded_text_frame()
  |> should.equal(
    "[\"join-ref\",null,\"room:1\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  )
}

// === Inbound shape ===

pub fn inbound_record_holds_normalized_fields_test() -> Nil {
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

pub fn inbound_supports_optional_refs_test() -> Nil {
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

pub fn public_codec_operations_apply_configured_behaviour_test() -> Nil {
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
      encode_reply: fn(_, _, _, _, _) { Ok(codec.TextFrame("reply")) },
      encode_push: fn(topic, event, _) {
        Ok(codec.TextFrame(topic <> ":" <> event))
      },
      encode_heartbeat_reply: fn(_) { Ok(codec.TextFrame("heartbeat")) },
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
  |> should.equal(Ok(codec.TextFrame("reply")))
  codec.apply_encode_push(
    base,
    topic: "room:1",
    event: "updated",
    payload: json.null(),
  )
  |> should.equal(Ok(codec.TextFrame("room:1:updated")))
  codec.apply_encode_heartbeat_reply(base, ref: None)
  |> should.equal(Ok(codec.TextFrame("heartbeat")))
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
      Ok(codec.TextFrame("close:" <> topic))
    })
    |> codec.with_error_encoder(fn(_, topic) {
      Ok(codec.TextFrame("error:" <> topic))
    })
    |> codec.with_topicless_events()

  let assert Some(Ok(binary_inbound)) =
    codec.apply_decode_binary(configured, data: <<1>>)
  codec.inbound_topic(binary_inbound) |> should.equal("binary")
  codec.apply_encode_close(configured, join_ref: None, topic: "room:1")
  |> should.equal(Some(Ok(codec.TextFrame("close:room:1"))))
  codec.apply_encode_error(configured, join_ref: None, topic: "room:1")
  |> should.equal(Some(Ok(codec.TextFrame("error:room:1"))))
  codec.uses_topicless_events(configured) |> should.be_true()
}

pub fn public_encode_operations_preserve_structured_errors_test() -> Nil {
  [
    codec.MetadataTooLong("topic", 256),
    codec.PayloadNotByteAligned,
    codec.EncodingRejected("unsupported response"),
  ]
  |> list.each(fn(error) {
    let rejecting =
      codec.new(
        decode_text: wire.decode_message,
        encode_reply: fn(_, _, _, _, _) { Error(error) },
        encode_push: fn(_, _, _) { Error(error) },
        encode_heartbeat_reply: fn(_) { Error(error) },
      )

    codec.apply_encode_reply(
      rejecting,
      join_ref: Some("join"),
      ref: Some("ref"),
      topic: "room:1",
      status: codec.StatusOk,
      response: json.null(),
    )
    |> should.equal(Error(error))
    codec.apply_encode_push(
      rejecting,
      topic: "room:1",
      event: "updated",
      payload: json.null(),
    )
    |> should.equal(Error(error))
    codec.apply_encode_heartbeat_reply(rejecting, ref: Some("ref"))
    |> should.equal(Error(error))

    // Missing optional callbacks and callbacks that failed are distinct states.
    codec.apply_encode_close(rejecting, join_ref: None, topic: "room:1")
    |> should.equal(None)
    codec.apply_encode_error(rejecting, join_ref: None, topic: "room:1")
    |> should.equal(None)

    let configured =
      rejecting
      |> codec.with_close_encoder(fn(_, _) { Error(error) })
      |> codec.with_error_encoder(fn(_, _) { Error(error) })
    codec.apply_encode_close(configured, join_ref: None, topic: "room:1")
    |> should.equal(Some(Error(error)))
    codec.apply_encode_error(configured, join_ref: None, topic: "room:1")
    |> should.equal(Some(Error(error)))
  })
}

pub fn public_encode_operations_only_invoke_selected_callback_test() -> Nil {
  // The subject is local to this test: it detects eager callbacks, retries,
  // fallback encoders, and any invocation beyond the requested operation.
  let calls = process.new_subject()
  let error = codec.EncodingRejected("test rejection")
  let rejecting =
    codec.new(
      decode_text: fn(_) {
        process.send(calls, "decode")
        Error(codec.InvalidFormat("unused"))
      },
      encode_reply: fn(_, _, _, _, _) {
        process.send(calls, "reply")
        Error(error)
      },
      encode_push: fn(_, _, _) {
        process.send(calls, "push")
        Error(error)
      },
      encode_heartbeat_reply: fn(_) {
        process.send(calls, "heartbeat")
        Error(error)
      },
    )
    |> codec.with_close_encoder(fn(_, _) {
      process.send(calls, "close")
      Error(error)
    })
    |> codec.with_error_encoder(fn(_, _) {
      process.send(calls, "error")
      Error(error)
    })

  // Construction does not call any callback.
  process.receive(calls, 0) |> should.equal(Error(Nil))

  codec.apply_encode_reply(
    rejecting,
    join_ref: None,
    ref: None,
    topic: "room:1",
    status: codec.StatusOk,
    response: json.null(),
  )
  |> should.equal(Error(error))
  process.receive(calls, 0) |> should.equal(Ok("reply"))
  process.receive(calls, 0) |> should.equal(Error(Nil))

  codec.apply_encode_push(
    rejecting,
    topic: "room:1",
    event: "updated",
    payload: json.null(),
  )
  |> should.equal(Error(error))
  process.receive(calls, 0) |> should.equal(Ok("push"))
  process.receive(calls, 0) |> should.equal(Error(Nil))

  codec.apply_encode_heartbeat_reply(rejecting, ref: None)
  |> should.equal(Error(error))
  process.receive(calls, 0) |> should.equal(Ok("heartbeat"))
  process.receive(calls, 0) |> should.equal(Error(Nil))

  codec.apply_encode_close(rejecting, join_ref: None, topic: "room:1")
  |> should.equal(Some(Error(error)))
  process.receive(calls, 0) |> should.equal(Ok("close"))
  process.receive(calls, 0) |> should.equal(Error(Nil))

  codec.apply_encode_error(rejecting, join_ref: None, topic: "room:1")
  |> should.equal(Some(Error(error)))
  process.receive(calls, 0) |> should.equal(Ok("error"))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}

pub fn binary_encode_error_adapter_preserves_structured_variants_test() -> Nil {
  [
    #(
      wire.MetadataTooLong("join_ref", 513),
      codec.MetadataTooLong("join_ref", 513),
    ),
    #(wire.MetadataTooLong("topic", 256), codec.MetadataTooLong("topic", 256)),
    #(wire.PayloadNotByteAligned, codec.PayloadNotByteAligned),
  ]
  |> list.each(fn(pair) {
    wire.binary_encode_error_to_encode_error(pair.0)
    |> should.equal(pair.1)
  })

  // A codec can adapt standalone helpers without changing their API.
  wire.binary_push(None, string.repeat("é", 128), "event", <<>>)
  |> result.map_error(wire.binary_encode_error_to_encode_error)
  |> should.equal(Error(codec.MetadataTooLong("topic", 256)))
  wire.binary_reply(None, None, "room:1", codec.StatusOk, <<1:size(1)>>)
  |> result.map_error(wire.binary_encode_error_to_encode_error)
  |> should.equal(Error(codec.PayloadNotByteAligned))
  wire.binary_broadcast("room:1", "event", <<1:size(1)>>)
  |> result.map_error(wire.binary_encode_error_to_encode_error)
  |> should.equal(Error(codec.PayloadNotByteAligned))
}

pub fn format_encode_error_describes_each_variant_test() -> Nil {
  codec.format_encode_error(codec.MetadataTooLong("topic", 256))
  |> should.equal("Metadata too long: topic (256 bytes)")
  codec.format_encode_error(codec.PayloadNotByteAligned)
  |> should.equal("Payload is not byte-aligned")
  codec.format_encode_error(codec.EncodingRejected("unsupported response"))
  |> should.equal("Encoding rejected: unsupported response")
}

pub fn dynamic_to_json_decodes_nested_json_values_test() -> Nil {
  let encoded = "[\"text\",1,1.5,true,null,{\"nested\":[false]}]"
  let assert Ok(dynamic_value) =
    json.parse(from: encoded, using: decode.dynamic)
  let assert Ok(json_value) = wire.dynamic_to_json(dynamic_value)

  json.to_string(json_value) |> should.equal(encoded)
}

pub fn dynamic_to_json_preserves_unicode_escaping_and_empty_containers_test() -> Nil {
  let text = "\"\\\n\r\t\u{0000}\u{00e9}\u{1f600}"
  let payload =
    dynamic.properties([
      #(
        dynamic.string(text),
        dynamic.list([
          dynamic.string(text),
          dynamic.list([]),
          dynamic.properties([]),
        ]),
      ),
    ])
  let assert Ok(converted) = wire.dynamic_to_json(payload)

  json.parse(from: json.to_string(converted), using: decode.dynamic)
  |> should.equal(Ok(payload))

  let assert Ok(native_array) =
    wire.dynamic_to_json(dynamic.array([dynamic.nil(), dynamic.list([])]))
  json.to_string(native_array) |> should.equal("[null,[]]")
}

pub fn dynamic_to_json_rejects_unsupported_values_and_object_keys_test() -> Nil {
  [
    dynamic.bit_array(<<255>>),
    dynamic.bit_array(<<1:size(1)>>),
    dynamic.array([dynamic.bit_array(<<255>>)]),
    dynamic.properties([#(dynamic.int(1), dynamic.nil())]),
    dynamic.properties([#(dynamic.bit_array(<<255>>), dynamic.nil())]),
  ]
  |> list.each(fn(value) {
    [
      value,
      dynamic.list([dynamic.int(1), value]),
      dynamic.properties([
        #(dynamic.string("valid"), dynamic.bool(True)),
        #(dynamic.string("invalid"), value),
      ]),
    ]
    |> list.each(fn(payload) {
      wire.dynamic_to_json(payload) |> should.equal(Error(Nil))
    })
  })
}

pub fn dynamic_to_json_and_encode_preserve_object_member_order_test() -> Nil {
  let wide_fields =
    list.repeat(Nil, 40)
    |> list.index_map(fn(_, index) {
      #("field_" <> int.to_string(index), index)
    })
  [[#("a", 1), #("b", 2)], wide_fields]
  |> list.each(fn(fields) {
    let payload =
      fields
      |> list.map(fn(field) { #(dynamic.string(field.0), dynamic.int(field.1)) })
      |> dynamic.properties
    let expected =
      fields
      |> dict.from_list
      |> dict.to_list
      |> list.map(fn(field) { #(field.0, json.int(field.1)) })
      |> json.object
      |> json.to_string
    let assert Ok(converted) = wire.dynamic_to_json(payload)
    json.to_string(converted) |> should.equal(expected)

    let message =
      codec.inbound(None, Some("r"), "room:1", codec.Event("event"), payload)
    wire.encode(message)
    |> should.equal(Ok("[null,\"r\",\"room:1\",\"event\"," <> expected <> "]"))
  })
}

pub fn dynamic_to_json_and_inbound_decoding_enforce_exact_depth_limit_test() -> Nil {
  [
    #("[", "]"),
    #("{\"child\":", "}"),
    #("{\"sibling\":0,\"child\":", "}"),
  ]
  |> list.each(fn(wrapping) {
    [#("null", 64), #("[]", 63), #("{}", 63)]
    |> list.each(fn(leaf) {
      let encoded =
        string.repeat(wrapping.0, leaf.1)
        <> leaf.0
        <> string.repeat(wrapping.1, leaf.1)
      let assert Ok(payload) = json.parse(from: encoded, using: decode.dynamic)
      let assert Ok(converted) = wire.dynamic_to_json(payload)
      json.parse(from: json.to_string(converted), using: decode.dynamic)
      |> should.equal(Ok(payload))
      wire.decode_message("[null,\"r\",\"room:1\",\"event\"," <> encoded <> "]")
      |> should.be_ok()

      let too_deep = wrapping.0 <> encoded <> wrapping.1
      let assert Ok(payload) = json.parse(from: too_deep, using: decode.dynamic)
      wire.dynamic_to_json(payload) |> should.equal(Error(Nil))
      let assert Error(codec.InvalidFormat(reason)) =
        wire.decode_message(
          "[null,\"r\",\"room:1\",\"event\"," <> too_deep <> "]",
        )
      reason |> should.equal("JSON nesting depth exceeded")
    })
  })
}

// === Reply status ===

pub fn reply_status_round_trips_through_phoenix_codec_test() -> Nil {
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
  encoded_text_frame(s)
  |> wire.decode_message()
  |> should.be_ok()
  Nil
}

pub fn phoenix_codec_decodes_shared_inbound_fixtures_test() -> Nil {
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

pub fn phoenix_codec_encodes_shared_server_push_fixtures_test() -> Nil {
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
        |> encoded_text_frame()
        |> should.equal(case_.encoded)
      Some(_), _, _ | None, _, _ -> Nil
    }
  })
}

pub fn phoenix_codec_encodes_shared_reply_fixtures_test() -> Nil {
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
    |> encoded_text_frame()
    |> should.equal(case_.encoded)
  })
}

pub fn phoenix_codec_encodes_shared_terminal_event_fixtures_test() -> Nil {
  let phoenix = wire.phoenix_codec()
  let assert Some(encode_close) = codec.encode_close(phoenix)
  let assert Some(encode_error) = codec.encode_error(phoenix)
  fixtures.server_outbound()
  |> list.each(fn(case_) {
    case case_.event {
      "phx_error" ->
        encode_error(case_.join_ref, case_.topic)
        |> encoded_text_frame()
        |> should.equal(case_.encoded)
      "phx_close" ->
        encode_close(case_.join_ref, case_.topic)
        |> encoded_text_frame()
        |> should.equal(case_.encoded)
      _ -> Nil
    }
  })
}

pub fn phoenix_terminal_events_mirror_join_ref_into_ref_test() -> Nil {
  wire.channel_close(Some("join-7"), "room:1")
  |> text_frame()
  |> should.equal("[\"join-7\",\"join-7\",\"room:1\",\"phx_close\",{}]")

  wire.channel_error(Some("join-7"), "room:1")
  |> text_frame()
  |> should.equal("[\"join-7\",\"join-7\",\"room:1\",\"phx_error\",{}]")
}

pub fn phoenix_codec_rejects_shared_invalid_fixtures_test() -> Nil {
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

pub fn phoenix_codec_rejects_excessively_nested_payload_test() -> Nil {
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

fn encoded_text_frame(
  encoded: Result(codec.Frame, codec.EncodeError),
) -> String {
  let assert Ok(frame) = encoded
  text_frame(frame)
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
