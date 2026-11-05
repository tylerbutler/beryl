import beryl/transport/server
import gleam/http/request
import gleeunit/should

pub fn compression_is_disabled_by_default_test() -> Nil {
  server.default_config("/socket")
  |> server.compression_enabled
  |> should.be_false
}

pub fn compression_requires_explicit_opt_in_test() -> Nil {
  server.default_config("/socket")
  |> server.with_compression
  |> server.compression_enabled
  |> should.be_true
}

pub fn default_removes_all_extension_offers_only_test() -> Nil {
  let original = request.new()
  let original =
    request.Request(..original, headers: [
      #("sec-websocket-extensions", "permessage-deflate"),
      #("Sec-WebSocket-Extensions", "permessage-deflate"),
      #("host", "example.test"),
      #("authorization", "Bearer test-token"),
      #("sec-websocket-protocol", "phoenix"),
    ])
  let prepared =
    server.prepare_websocket_request(original, server.default_config("/socket"))
  prepared.headers
  |> should.equal([
    #("host", "example.test"),
    #("authorization", "Bearer test-token"),
    #("sec-websocket-protocol", "phoenix"),
  ])
  let seed = server.connect_seed(original, [])
  seed.headers |> should.equal(original.headers)
}

pub fn opt_in_preserves_the_original_request_test() -> Nil {
  let original =
    request.new()
    |> request.set_header("sec-websocket-extensions", "permessage-deflate")
  let config = server.default_config("/socket") |> server.with_compression
  server.prepare_websocket_request(original, config)
  |> should.equal(original)
}

pub fn no_offer_remains_unchanged_test() -> Nil {
  let original = request.new()
  server.prepare_websocket_request(original, server.default_config("/socket"))
  |> should.equal(original)
}
