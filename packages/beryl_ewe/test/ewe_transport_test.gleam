//// Compile-level checks that `beryl/transport/server`'s config builders
//// instantiate against Ewe's connection body type, and that this package's
//// documented entry points stay exported.
////
//// The builders' behavior and the origin policy are covered once in
//// `packages/beryl`; only the Ewe-specific instantiation belongs here.

import beryl/transport/server
import beryl_ewe as ewe_transport
import ewe.{type Connection}
import gleam/http/request.{type Request}
import gleeunit/should

pub fn config_builders_instantiate_for_ewe_test() {
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

// `upgrade` is the path-matching entry point used by callers that compose their
// own request handler. Reference it here so the export stays covered.
pub fn upgrade_is_exported_test() {
  let _upgrade = ewe_transport.upgrade
  should.be_true(True)
}
