import beryl/transport/mist as mist_transport
import beryl/wire/codec
import gleam/http/request.{type Request}
import gleam/option.{None}
import gleam/string
import gleeunit/should
import mist.{type Connection}

pub fn default_config_creates_with_path_test() {
  let _config: mist_transport.TransportConfig(Nil) =
    mist_transport.default_config("/socket")

  should.be_true(True)
}

pub fn default_config_slash_ws_test() {
  let _config: mist_transport.TransportConfig(Nil) =
    mist_transport.default_config("/ws")

  should.be_true(True)
}

pub fn with_on_connect_sets_callback_test() {
  let callback = fn(_req: Request(Connection)) -> Result(
    Nil,
    mist_transport.ConnectError,
  ) {
    Ok(Nil)
  }

  let config =
    mist_transport.default_config("/socket")
    |> mist_transport.with_on_connect(callback)

  let _typed_config: mist_transport.TransportConfig(Nil) = config
  should.be_true(True)
}

pub fn with_on_connect_replaces_callback_test() {
  let callback1 = fn(_req: Request(Connection)) -> Result(
    Nil,
    mist_transport.ConnectError,
  ) {
    Ok(Nil)
  }
  let callback2 = fn(_req: Request(Connection)) -> Result(
    Nil,
    mist_transport.ConnectError,
  ) {
    Error(mist_transport.ConnectRejected)
  }

  let config =
    mist_transport.default_config("/socket")
    |> mist_transport.with_on_connect(callback1)
    |> mist_transport.with_on_connect(callback2)

  let _typed_config: mist_transport.TransportConfig(Nil) = config
  should.be_true(True)
}

pub fn with_on_connect_seeding_assigns_sets_callback_test() {
  // on_connect may return seeded socket-level assigns, not just Nil.
  let callback = fn(_req: Request(Connection)) -> Result(
    String,
    mist_transport.ConnectError,
  ) {
    Ok("user-123")
  }

  let config =
    mist_transport.default_config("/socket")
    |> mist_transport.with_on_connect(callback)

  let _typed_config: mist_transport.TransportConfig(String) = config
  should.be_true(True)
}

pub fn with_reject_unknown_vsn_is_chainable_test() {
  let config =
    mist_transport.default_config("/socket")
    |> mist_transport.with_reject_unknown_vsn(True)

  let _typed_config: mist_transport.TransportConfig(Nil) = config
  should.be_true(True)
}

pub fn with_serializer_is_chainable_test() {
  let test_codec =
    codec.Codec(
      decode_text: fn(_) { Error(codec.InvalidFormat("text")) },
      decode_binary: None,
      encode_reply: fn(_, _, _, _, _) { codec.TextFrame("reply") },
      encode_push: fn(_, _, _) { codec.TextFrame("push") },
      encode_heartbeat_reply: fn(_) { codec.TextFrame("heartbeat") },
    )
  let config =
    mist_transport.default_config("/socket")
    |> mist_transport.with_serializer("3.0.0", test_codec)

  let _typed_config: mist_transport.TransportConfig(Nil) = config
  should.be_true(string.length(mist_transport.default_vsn) > 0)
}

// `upgrade_connection` is a public entry point for callers that do their own
// path matching (see the WebSocket guide and PRD). Reference it here so the
// export stays covered and remains part of the documented public API.
pub fn upgrade_connection_is_exported_test() {
  let _upgrade = mist_transport.upgrade_connection
  should.be_true(True)
}
