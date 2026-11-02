import beryl_codec_bench/fixture
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import unitest

pub fn main() -> Nil {
  unitest.main()
}

pub fn fixture_preflight_checks_all_codec_operations_test() -> Nil {
  let assert Ok(texts) = fixture.text()
  fixture.preflight(texts, fixture.binary()) |> should.equal(Ok(Nil))
}

pub fn sized_payloads_have_exact_body_byte_counts_test() -> Nil {
  let assert Ok(texts) = fixture.text()
  let bodies =
    texts
    |> list.take(3)
    |> list.map(fn(input) {
      let assert Ok(body) =
        json.parse(
          json.to_string(input.payload),
          decode.at(["body"], decode.string),
        )
      body |> bit_array.from_string |> bit_array.byte_size
    })
  bodies |> should.equal([128, 4096, 65_536])
  fixture.binary()
  |> list.map(fn(input) { bit_array.byte_size(input.payload) })
  |> should.equal(bodies)
}

pub fn corrupted_text_fixture_fails_before_measurement_test() -> Nil {
  let assert Ok([first, ..rest]) = fixture.text()
  let corrupted = fixture.TextFixture(..first, frame: "[null,null]")
  let assert Error(fixture.Failure(label, reason)) =
    fixture.preflight([corrupted, ..rest], fixture.binary())
  label |> should.equal(first.label)
  reason
  |> string.contains("Decoded fields or payload differ")
  |> should.be_true
}

pub fn corrupted_binary_fixture_fails_before_measurement_test() -> Nil {
  let assert Ok(texts) = fixture.text()
  let assert [first, ..rest] = fixture.binary()
  let corrupted = fixture.BinaryFixture(..first, payload: <<>>)
  let assert Error(fixture.Failure(label, reason)) =
    fixture.preflight(texts, [corrupted, ..rest])
  label |> should.equal(first.label)
  reason
  |> should.equal("Decoded binary fields or payload differ")
}
