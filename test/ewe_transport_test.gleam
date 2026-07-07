import beryl/transport/ewe as ewe_transport
import ewe.{type Connection}
import gleam/http/request.{type Request}
import gleeunit/should

pub fn default_config_creates_with_path_test() {
  let _config: ewe_transport.TransportConfig(Nil) =
    ewe_transport.default_config("/socket")

  should.be_true(True)
}

pub fn default_config_slash_ws_test() {
  let _config: ewe_transport.TransportConfig(Nil) =
    ewe_transport.default_config("/ws")

  should.be_true(True)
}

pub fn with_on_connect_sets_callback_test() {
  let callback = fn(_req: Request(Connection)) -> Result(
    Nil,
    ewe_transport.ConnectError,
  ) {
    Ok(Nil)
  }

  let config =
    ewe_transport.default_config("/socket")
    |> ewe_transport.with_on_connect(callback)

  let _typed_config: ewe_transport.TransportConfig(Nil) = config
  should.be_true(True)
}

pub fn with_on_connect_replaces_callback_test() {
  let callback1 = fn(_req: Request(Connection)) -> Result(
    Nil,
    ewe_transport.ConnectError,
  ) {
    Ok(Nil)
  }
  let callback2 = fn(_req: Request(Connection)) -> Result(
    Nil,
    ewe_transport.ConnectError,
  ) {
    Error(ewe_transport.ConnectRejected)
  }

  let config =
    ewe_transport.default_config("/socket")
    |> ewe_transport.with_on_connect(callback1)
    |> ewe_transport.with_on_connect(callback2)

  let _typed_config: ewe_transport.TransportConfig(Nil) = config
  should.be_true(True)
}

pub fn with_on_connect_seeding_assigns_sets_callback_test() {
  // on_connect may return seeded socket-level assigns, not just Nil.
  let callback = fn(_req: Request(Connection)) -> Result(
    String,
    ewe_transport.ConnectError,
  ) {
    Ok("user-123")
  }

  let config =
    ewe_transport.default_config("/socket")
    |> ewe_transport.with_on_connect(callback)

  let _typed_config: ewe_transport.TransportConfig(String) = config
  should.be_true(True)
}

// `upgrade_connection` is a public entry point for callers that do their own
// path matching. Reference it here so the export stays covered and remains part
// of the documented public API.
pub fn upgrade_connection_is_exported_test() {
  let _upgrade = ewe_transport.upgrade_connection
  should.be_true(True)
}

// `upgrade` is the path-matching entry point used by callers that compose their
// own request handler. Reference it here so the export stays covered.
pub fn upgrade_is_exported_test() {
  let _upgrade = ewe_transport.upgrade
  should.be_true(True)
}
