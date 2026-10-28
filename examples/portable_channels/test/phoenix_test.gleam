import gleam/bit_array
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import phoenix_channel_fixtures
import phoenix_channel_fixtures/frame as fixture
import portable_channels/phoenix
import roost
import roost/frame

pub fn client_fixtures_decode_through_the_host_adapter_test() -> Nil {
  phoenix_channel_fixtures.client_outbound()
  |> list.each(fn(example) {
    let assert Ok(decoded) = phoenix.decode(frame.TextData(example.encoded))
    decoded.join_ref |> should.equal(example.join_ref)
    decoded.ref |> should.equal(example.ref)
    decoded.topic |> should.equal(example.topic)
    decoded.event |> should.equal(example.event)
  })
}

pub fn server_fixtures_encode_through_roost_test() -> Nil {
  phoenix_channel_fixtures.server_outbound()
  |> list.each(fn(example) {
    phoenix.encode(
      example.join_ref,
      example.ref,
      example.topic,
      example.event,
      example.payload,
    )
    |> should.equal(Ok(frame.TextData(example.encoded)))
  })
  phoenix_channel_fixtures.replies()
  |> list.each(fn(example) {
    let succeeded = case example.status {
      fixture.StatusOk -> True
      fixture.StatusError -> False
    }
    phoenix.reply(
      example.join_ref,
      Some(example.ref),
      example.topic,
      succeeded,
      example.response,
    )
    |> should.equal(Ok(frame.TextData(example.encoded)))
  })
}

pub fn invalid_fixtures_fail_at_the_codec_boundary_test() -> Nil {
  phoenix_channel_fixtures.invalid_frames()
  |> list.each(fn(example) {
    phoenix.decode(frame.TextData(example.encoded))
    |> should.be_error
  })
}

pub fn binary_client_push_uses_phoenix_v2_headers_test() -> Nil {
  let bytes = <<
    0,
    1,
    1,
    6,
    6,
    "j":utf8,
    "r":utf8,
    "room:a":utf8,
    "upload":utf8,
    1,
    2,
    255,
  >>
  let assert Ok(decoded) = phoenix.decode(frame.BinaryData(bytes))
  decoded.join_ref |> should.equal(Some("j"))
  decoded.ref |> should.equal(Some("r"))
  decoded.topic |> should.equal("room:a")
  decoded.event |> should.equal("upload")

  roost.encode(
    frame.Push(
      Some("j"),
      Some("r"),
      "room:a",
      "upload",
      frame.BinaryPayload(<<1, 2, 255>>),
    ),
    frame.ClientToServer,
  )
  |> should.equal(Ok(frame.BinaryData(bytes)))
}

pub fn binary_server_reply_keeps_its_direction_specific_header_test() -> Nil {
  let assert Ok(frame.BinaryData(bytes)) =
    roost.encode(
      frame.Reply(
        Some("j"),
        "r",
        "room:a",
        frame.StatusOk,
        frame.BinaryPayload(<<1, 2, 255>>),
      ),
      frame.ServerToClient,
    )
  bytes
  |> should.equal(<<
    1,
    1,
    1,
    6,
    2,
    "j":utf8,
    "r":utf8,
    "room:a":utf8,
    "ok":utf8,
    1,
    2,
    255,
  >>)
  let assert Ok(frame.Reply(join_ref, ref, topic, status, response)) =
    roost.decode(frame.BinaryData(bytes), frame.ServerToClient)
  #(join_ref, ref, topic, status)
  |> should.equal(#(Some("j"), "r", "room:a", frame.StatusOk))
  response |> should.equal(frame.BinaryPayload(<<1, 2, 255>>))
}

pub fn replies_without_a_wire_ref_preserve_the_null_field_test() -> Nil {
  phoenix.reply(None, None, "room:a", True, json.object([]))
  |> should.equal(
    Ok(frame.TextData(
      "[null,null,\"room:a\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
    )),
  )
}

pub fn malformed_binary_frames_fail_before_application_delivery_test() -> Nil {
  let _error =
    phoenix.decode(frame.BinaryData(bit_array.from_string("not a frame")))
    |> should.be_error
  Nil
}
