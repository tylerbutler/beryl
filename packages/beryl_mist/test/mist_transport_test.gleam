//// Compile-level checks that `beryl/transport/server`'s config builders
//// instantiate against Mist's connection body type.
////
//// The builders' behavior and the origin policy are covered once in
//// `packages/beryl`; only the Mist-specific instantiation belongs here.

import beryl/transport/server
import gleam/http/request.{type Request}
import gleeunit/should
import mist.{type Connection}

pub fn config_builders_instantiate_for_mist_test() -> Nil {
  let on_connect = fn(_request: Request(Connection)) -> Result(
    List(#(String, String)),
    server.ConnectError,
  ) {
    Ok([#("user", "user-123")])
  }

  let _typed_config: server.TransportConfig(Connection) =
    server.default_config("/socket")
    |> server.with_on_connect(fn(_request) { Error(server.ConnectRejected) })
    |> server.with_on_connect(on_connect)
    |> server.with_allowed_origins(["https://app.example.com"])
    |> server.with_allow_all_origins()

  should.be_true(True)
}
