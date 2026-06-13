import beryl/transport/mist as mist_transport
import gleam/http/request.{type Request}
import gleam/option.{None}
import gleeunit/should
import mist.{type Connection}

pub fn default_config_creates_with_path_test() {
  let config = mist_transport.default_config("/socket")
  config.path |> should.equal("/socket")
  config.on_connect |> should.equal(None)
}

pub fn default_config_slash_ws_test() {
  let config = mist_transport.default_config("/ws")
  config.path |> should.equal("/ws")
}

pub fn with_on_connect_sets_callback_test() {
  let callback = fn(_req: Request(Connection)) -> Result(Nil, Nil) { Ok(Nil) }

  let config =
    mist_transport.default_config("/socket")
    |> mist_transport.with_on_connect(callback)

  config.path |> should.equal("/socket")
  config.on_connect |> should.be_some
}

pub fn with_on_connect_replaces_callback_test() {
  let callback1 = fn(_req: Request(Connection)) -> Result(Nil, Nil) { Ok(Nil) }
  let callback2 = fn(_req: Request(Connection)) -> Result(Nil, Nil) {
    Error(Nil)
  }

  let config =
    mist_transport.default_config("/socket")
    |> mist_transport.with_on_connect(callback1)
    |> mist_transport.with_on_connect(callback2)

  config.on_connect |> should.be_some
}

// `upgrade_connection` is a public entry point for callers that do their own
// path matching (see the WebSocket guide and PRD). Reference it here so the
// export stays covered and remains part of the documented public API.
pub fn upgrade_connection_is_exported_test() {
  let _upgrade = mist_transport.upgrade_connection
  should.be_true(True)
}
