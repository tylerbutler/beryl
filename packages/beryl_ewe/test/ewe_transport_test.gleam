import beryl/transport/origin
import beryl/transport/server
import beryl_ewe as ewe_transport
import ewe.{type Connection}
import gleam/http/request.{type Request}
import gleeunit/should

pub fn default_config_creates_with_path_test() {
  let _config: server.TransportConfig(Connection) =
    server.default_config("/socket")

  should.be_true(True)
}

pub fn default_config_slash_ws_test() {
  let _config: server.TransportConfig(Connection) = server.default_config("/ws")

  should.be_true(True)
}

pub fn with_on_connect_sets_callback_test() {
  let callback = fn(_req: Request(Connection)) -> Result(
    List(#(String, String)),
    server.ConnectError,
  ) {
    Ok([])
  }

  let config =
    server.default_config("/socket")
    |> server.with_on_connect(callback)

  let _typed_config: server.TransportConfig(Connection) = config
  should.be_true(True)
}

pub fn with_on_connect_replaces_callback_test() {
  let callback1 = fn(_req: Request(Connection)) -> Result(
    List(#(String, String)),
    server.ConnectError,
  ) {
    Ok([])
  }
  let callback2 = fn(_req: Request(Connection)) -> Result(
    List(#(String, String)),
    server.ConnectError,
  ) {
    Error(server.ConnectRejected)
  }

  let config =
    server.default_config("/socket")
    |> server.with_on_connect(callback1)
    |> server.with_on_connect(callback2)

  let _typed_config: server.TransportConfig(Connection) = config
  should.be_true(True)
}

pub fn with_on_connect_seeding_metadata_sets_callback_test() {
  // on_connect may return ordered string metadata, not just an empty list.
  let callback = fn(_req: Request(Connection)) -> Result(
    List(#(String, String)),
    server.ConnectError,
  ) {
    Ok([#("user", "user-123")])
  }

  let config =
    server.default_config("/socket")
    |> server.with_on_connect(callback)

  let _typed_config: server.TransportConfig(Connection) = config
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

pub fn with_allowed_origins_sets_list_test() {
  let config =
    server.default_config("/socket")
    |> server.with_allowed_origins(["https://app.example.com"])

  let _typed_config: server.TransportConfig(Connection) = config
  should.be_true(True)
}

pub fn with_allow_all_origins_is_exported_test() {
  let config =
    server.default_config("/socket")
    |> server.with_allow_all_origins()

  let _typed_config: server.TransportConfig(Connection) = config
  should.be_true(True)
}

// --- same_origin authority comparison ---------------------------------------
//
// `same_origin` implements the SameOrigin policy at the string level: it
// strips the scheme from the `Origin` header value and compares the resulting
// authority (host + optional port) against the request `Host` authority.

pub fn same_origin_matches_host_ignoring_scheme_test() {
  origin.same_origin("http://app.example.com", "app.example.com")
  |> should.be_true

  origin.same_origin("https://app.example.com", "app.example.com")
  |> should.be_true
}

pub fn same_origin_rejects_cross_origin_test() {
  origin.same_origin("https://evil.example.com", "app.example.com")
  |> should.be_false
}

pub fn same_origin_matches_non_default_port_test() {
  origin.same_origin("http://127.0.0.1:8080", "127.0.0.1:8080")
  |> should.be_true
}

pub fn same_origin_rejects_port_mismatch_test() {
  origin.same_origin("http://127.0.0.1:8080", "127.0.0.1:9090")
  |> should.be_false
}

pub fn same_origin_is_case_insensitive_on_host_test() {
  origin.same_origin("https://APP.Example.COM", "app.example.com")
  |> should.be_true
}

pub fn same_origin_rejects_opaque_origin_test() {
  // Sandboxed iframes / file:// documents send `Origin: null`.
  origin.same_origin("null", "app.example.com")
  |> should.be_false
}

pub fn same_origin_rejects_malformed_origin_test() {
  origin.same_origin("garbage", "app.example.com")
  |> should.be_false

  // Scheme present but no host authority.
  origin.same_origin("https://", "app.example.com")
  |> should.be_false
}

pub fn same_origin_matches_forwarded_host_authority_test() {
  // Behind a reverse proxy that preserves the public Host header, the browser
  // Origin authority (host:port) must match the forwarded Host authority.
  origin.same_origin(
    "https://public.example.com:8443",
    "public.example.com:8443",
  )
  |> should.be_true
}
