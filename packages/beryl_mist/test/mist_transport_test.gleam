//// Compile-level checks that `beryl/transport/server`'s config builders
//// instantiate against Mist's connection body type, and that this package's
//// documented entry points stay exported.
////
//// The builders' behavior and the origin policy are covered once in
//// `packages/beryl`; only the Mist-specific instantiation belongs here.

import beryl/transport/server
import beryl_mist as mist_transport
import gleam/http/request.{type Request}
import gleeunit/should
import mist.{type Connection}

pub fn config_builders_instantiate_for_mist_test() {
  let on_connect = fn(_req: Request(Connection)) -> Result(
    List(#(String, String)),
    server.ConnectError,
  ) {
    Ok([#("user", "user-123")])
  }

  let _typed_config: server.TransportConfig(Connection) =
    server.default_config("/socket")
    |> server.with_on_connect(fn(_req) { Error(server.ConnectRejected) })
    |> server.with_on_connect(on_connect)
    |> server.with_allowed_origins(["https://app.example.com"])
    |> server.with_allow_all_origins()

  should.be_true(True)
}

// `upgrade_connection` is a public entry point for callers that do their own
// path matching (see the WebSocket guide and PRD). Reference it here so the
// export stays covered and remains part of the documented public API.
pub fn upgrade_connection_is_exported_test() {
  let _upgrade = mist_transport.upgrade_connection
  should.be_true(True)
}
