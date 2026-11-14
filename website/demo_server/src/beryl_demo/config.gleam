//// Configuration constants and environment loading for the beryl demo
//// service.

import envoy
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Protocol compatibility version advertised on `/v1/status` and required from
/// every join payload.
pub const compatibility_version = 1

/// Well-known scenario identifier for the demo presence channel.
pub const scenario = "presence-v1"

/// WebSocket upgrade path served by the demo listener.
pub const socket_path = "/socket/websocket"

/// Runtime configuration for the demo service.
pub type Config {
  Config(
    port: Int,
    bind_address: String,
    allowed_origins: List(String),
    beryl_version: String,
    session_ttl_ms: Int,
  )
}

/// Built-in defaults locked to the documentation site origins.
pub fn default() -> Config {
  Config(
    port: 4100,
    bind_address: "127.0.0.1",
    allowed_origins: [
      "https://beryl.tylerbutler.com",
      "http://127.0.0.1:4321",
      "http://localhost:4321",
    ],
    beryl_version: "development",
    session_ttl_ms: 600_000,
  )
}

/// Split a comma-separated origin list, trimming whitespace and dropping
/// empty entries.
pub fn parse_origins(value: String) -> List(String) {
  value
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(origin) { origin != "" })
}

/// Build a `Config` from environment variables, falling back to `default()`
/// values for anything unset.
pub fn from_env() -> Config {
  let defaults = default()
  Config(
    port: envoy.get("PORT")
      |> result.try(int.parse)
      |> result.unwrap(defaults.port),
    bind_address: envoy.get("BIND_ADDRESS")
      |> result.unwrap(defaults.bind_address),
    allowed_origins: envoy.get("ALLOWED_ORIGINS")
      |> result.map(parse_origins)
      |> result.unwrap(defaults.allowed_origins),
    beryl_version: envoy.get("BERYL_VERSION")
      |> result.unwrap(defaults.beryl_version),
    session_ttl_ms: defaults.session_ttl_ms,
  )
}
