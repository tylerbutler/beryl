import beryl/wire
import beryl/wire/codec
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub type Failure {
  Failure(label: String, reason: String)
}

pub type TextFixture {
  TextFixture(
    label: String,
    payload: json.Json,
    inbound: codec.Inbound,
    frame: String,
  )
}

pub type BinaryFixture {
  BinaryFixture(label: String, payload: BitArray, frame: BitArray)
}

pub type RejectionKind {
  JsonError
  FormatError
}

pub type TextRejection {
  TextRejection(label: String, frame: String, kind: RejectionKind)
}

/// Build text inputs before measurements, including payload depth boundaries.
pub fn text() -> Result(List(TextFixture), Failure) {
  let sized =
    list.map([128, 4096, 65_536], fn(size) {
      #(
        "body_bytes=" <> int.to_string(size),
        json.object([#("body", json.string(string.repeat("a", size)))]),
      )
    })
  let nested =
    list.map([8, 64], fn(depth) {
      #(
        "nested_arrays=" <> int.to_string(depth),
        list.fold(list.repeat(Nil, depth), json.null(), fn(payload, _) {
          json.preprocessed_array([payload])
        }),
      )
    })
  list.append(sized, nested)
  |> list.try_map(fn(input) {
    let #(label, payload) = input
    let encoded = json.to_string(payload)
    use dynamic_payload <- result.try(
      json.parse(encoded, decode.dynamic)
      |> result.map_error(fn(_) { Failure(label, "Cannot parse fixture JSON") }),
    )
    let frame = "[\"j1\",\"r1\",\"bench:codec\",\"echo\"," <> encoded <> "]"
    Ok(TextFixture(
      label: label
        <> " json_bytes="
        <> int.to_string(string_bytes(encoded))
        <> " frame_bytes="
        <> int.to_string(string_bytes(frame)),
      payload: payload,
      inbound: codec.inbound(
        join_ref: Some("j1"),
        ref: Some("r1"),
        topic: "bench:codec",
        kind: codec.Event("echo"),
        payload: dynamic_payload,
      ),
      frame: frame,
    ))
  })
}

/// Build client-push frames, not the different server-push layout.
pub fn binary() -> List(BinaryFixture) {
  list.map([128, 4096, 65_536], fn(size) {
    let payload = bit_array.from_string(string.repeat("a", size))
    let frame = <<
      0, 2, 2, 11, 4, "j1":utf8, "r1":utf8, "bench:codec":utf8, "echo":utf8,
      payload:bits,
    >>
    BinaryFixture(
      label: "body_bytes="
        <> int.to_string(size)
        <> " frame_bytes="
        <> int.to_string(bit_array.byte_size(frame)),
      payload: payload,
      frame: frame,
    )
  })
}

/// Representative failures are separate from the successful input matrix.
pub fn rejected_text() -> List(TextRejection) {
  [
    TextRejection("malformed_json", "[", JsonError),
    TextRejection("wrong_array_shape", "[null,null]", FormatError),
    TextRejection(
      "invalid_topic_type",
      "[null,null,42,\"echo\",{}]",
      FormatError,
    ),
    TextRejection(
      "nested_arrays=65",
      "[null,null,\"bench:codec\",\"echo\","
        <> string.repeat("[", 65)
        <> "null"
        <> string.repeat("]", 65)
        <> "]",
      FormatError,
    ),
  ]
}

/// Invalid metadata exercises binary validation without a payload workload.
pub fn rejected_binary() -> List(#(String, BitArray)) {
  [
    #("truncated_metadata", <<0, 0, 0, 11, 4, "short":utf8>>),
    #("unsupported_kind", <<2, 0, 0, 0, 0>>),
    #("invalid_utf8_topic", <<0, 0, 0, 1, 1, 255, "e":utf8>>),
  ]
}

/// Check all fixtures and encoder results without running measurements.
pub fn preflight(
  texts: List(TextFixture),
  binaries: List(BinaryFixture),
) -> Result(Nil, Failure) {
  use _ <- result.try(list.try_map(texts, check_text))
  use _ <- result.try(list.try_map(binaries, check_binary))
  use _ <- result.try(
    list.try_map(rejected_text(), fn(input) {
      let expected = case wire.decode_message(input.frame) {
        Error(codec.InvalidJson(_)) -> input.kind == JsonError
        Error(codec.InvalidFormat(_)) -> input.kind == FormatError
        Ok(_) | Error(codec.MissingField(_)) -> False
      }
      expect(input.label, expected, "Unexpected text rejection result")
    }),
  )
  use _ <- result.try(
    list.try_map(rejected_binary(), fn(input) {
      let #(label, frame) = input
      let expected = case wire.decode_binary_message(frame) {
        Error(codec.InvalidFormat(_)) -> True
        Ok(_) | Error(codec.InvalidJson(_)) | Error(codec.MissingField(_)) ->
          False
      }
      expect(label, expected, "Unexpected binary rejection result")
    }),
  )
  check_metadata_boundary()
}

fn check_text(input: TextFixture) -> Result(Nil, Failure) {
  use _ <- result.try(expect(
    input.label,
    wire.decode_message(input.frame) == Ok(input.inbound),
    "Decoded fields or payload differ",
  ))
  use encoded <- result.try(
    wire.encode(input.inbound)
    |> result.map_error(fn(_) {
      Failure(input.label, "Inbound encoding failed")
    }),
  )
  use _ <- result.try(expect(
    input.label,
    wire.decode_message(encoded) == Ok(input.inbound),
    "Re-encoding changed the message",
  ))
  let payload = json.to_string(input.payload)
  use _ <- result.try(expect(
    input.label,
    wire.push("bench:codec", "echo", input.payload)
      == codec.TextFrame(
      "[null,null,\"bench:codec\",\"echo\"," <> payload <> "]",
    ),
    "Push encoding changed the frame",
  ))
  expect(
    input.label,
    wire.reply_json(
      Some("j1"),
      Some("r1"),
      "bench:codec",
      codec.StatusOk,
      input.payload,
    )
      == codec.TextFrame(
      "[\"j1\",\"r1\",\"bench:codec\",\"phx_reply\","
      <> "{\"status\":\"ok\",\"response\":"
      <> payload
      <> "}]",
    ),
    "Reply encoding changed the frame",
  )
}

fn check_binary(input: BinaryFixture) -> Result(Nil, Failure) {
  use inbound <- result.try(
    wire.decode_binary_message(input.frame)
    |> result.map_error(fn(error) {
      Failure(input.label, codec.format_decode_error(error))
    }),
  )
  use _ <- result.try(expect(
    input.label,
    codec.inbound_join_ref(inbound) == Some("j1")
      && codec.inbound_ref(inbound) == Some("r1")
      && codec.inbound_topic(inbound) == "bench:codec"
      && codec.inbound_kind(inbound) == codec.Event("echo")
      && decode.run(codec.inbound_payload(inbound), decode.bit_array)
      == Ok(input.payload),
    "Decoded binary fields or payload differ",
  ))
  let payload = input.payload
  use _ <- result.try(expect(
    input.label,
    wire.binary_push(Some("j1"), "bench:codec", "echo", payload)
      == Ok(
      codec.BinaryFrame(<<
        0, 2, 11, 4, "j1":utf8, "bench:codec":utf8, "echo":utf8, payload:bits,
      >>),
    ),
    "Server binary push layout differs",
  ))
  use _ <- result.try(expect(
    input.label,
    wire.binary_reply(
      Some("j1"),
      Some("r1"),
      "bench:codec",
      codec.StatusOk,
      payload,
    )
      == Ok(
      codec.BinaryFrame(<<
        1, 2, 2, 11, 2, "j1":utf8, "r1":utf8, "bench:codec":utf8, "ok":utf8,
        payload:bits,
      >>),
    ),
    "Server binary reply layout differs",
  ))
  expect(
    input.label,
    wire.binary_broadcast("bench:codec", "echo", payload)
      == Ok(
      codec.BinaryFrame(<<
        2, 11, 4, "bench:codec":utf8, "echo":utf8, payload:bits,
      >>),
    ),
    "Server binary broadcast layout differs",
  )
}

fn check_metadata_boundary() -> Result(Nil, Failure) {
  let topic = string.repeat("a", 255)
  let accepted = case wire.binary_push(None, topic, "echo", <<>>) {
    Ok(codec.BinaryFrame(<<
      0,
      0,
      255,
      4,
      encoded_topic:bytes-size(255),
      "echo":utf8,
    >>)) -> encoded_topic == bit_array.from_string(topic)
    Ok(codec.BinaryFrame(_)) | Ok(codec.TextFrame(_)) | Error(_) -> False
  }
  use _ <- result.try(expect(
    "topic_bytes=255",
    accepted,
    "Maximum metadata length was not encoded correctly",
  ))
  expect(
    "topic_bytes=256",
    wire.binary_push(None, topic <> "a", "echo", <<>>)
      == Error(wire.MetadataTooLong("topic", 256)),
    "Oversized metadata was not rejected",
  )
}

fn expect(
  label: String,
  condition: Bool,
  reason: String,
) -> Result(Nil, Failure) {
  case condition {
    True -> Ok(Nil)
    False -> Error(Failure(label, reason))
  }
}

fn string_bytes(value: String) -> Int {
  value |> bit_array.from_string |> bit_array.byte_size
}
