//// Persistent tests for the narrowly approved Ewe 9.0.0 private-layout shim.
//// Dynamic is intentional here: malformed layouts have no Connection value.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleeunit/should

type Fixture {
  Websocket
  MissingHandshakeFields
  NoExtensions
  OtherUpgrade
  NoUpgrade
  Http2
}

@external(erlang, "beryl_ewe_compression_test_ffi", "fixture")
fn fixture(kind: Fixture) -> #(Dynamic, Dynamic)

@external(erlang, "beryl_ewe_compression_test_ffi", "malformed")
fn malformed() -> List(Dynamic)

@external(erlang, "beryl_ewe_compression_ffi", "disable_cached_compression")
fn disable_cached_compression(connection: Dynamic) -> Result(Dynamic, Nil)

pub fn http1_clears_only_extensions_preserving_every_other_field_test() {
  let #(connection, expected) = fixture(Websocket)
  disable_cached_compression(connection) |> should.equal(Ok(expected))
}

pub fn malformed_handshake_values_remain_for_ewe_validation_test() {
  let #(connection, expected) = fixture(MissingHandshakeFields)
  disable_cached_compression(connection) |> should.equal(Ok(expected))
}

pub fn absent_extensions_are_idempotent_test() {
  let #(connection, expected) = fixture(NoExtensions)
  disable_cached_compression(connection) |> should.equal(Ok(expected))
}

pub fn other_upgrade_metadata_is_untouched_test() {
  let #(connection, expected) = fixture(OtherUpgrade)
  disable_cached_compression(connection) |> should.equal(Ok(expected))
}

pub fn no_upgrade_metadata_is_untouched_test() {
  let #(connection, expected) = fixture(NoUpgrade)
  disable_cached_compression(connection) |> should.equal(Ok(expected))
}

pub fn http2_connection_is_untouched_test() {
  let #(connection, expected) = fixture(Http2)
  disable_cached_compression(connection) |> should.equal(Ok(expected))
}

pub fn unexpected_layouts_fail_closed_test() {
  list.each(malformed(), fn(connection) {
    disable_cached_compression(connection) |> should.equal(Error(Nil))
  })
}
