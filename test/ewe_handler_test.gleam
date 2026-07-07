//// Integration tests for the combined `ewe_transport.handler`.
////
//// These spin up a real Ewe listener so we can verify how the composed
//// handler routes WebSocket upgrades versus plain HTTP requests. They reuse
//// the server-agnostic raw-TCP WebSocket client FFI shared with the Mist
//// transport tests.

import beryl
import beryl/transport/ewe as ewe_transport
import beryl/wire
import ewe
import gleam/erlang/process
import gleam/http/response
import gleam/string
import gleeunit/should

type WebsocketClient

@external(erlang, "beryl_mist_transport_test_ffi", "connect_websocket")
fn connect_websocket(port: Int, path: String) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "connect_websocket_with_origin")
fn connect_websocket_with_origin(
  port: Int,
  path: String,
  origin: String,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "websocket_upgrade_status_with_origin")
fn websocket_upgrade_status_with_origin(
  port: Int,
  path: String,
  origin: String,
) -> Result(Int, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "websocket_upgrade_status")
fn websocket_upgrade_status(port: Int, path: String) -> Result(Int, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "send_text")
fn send_text(
  client: WebsocketClient,
  text: String,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "receive_text")
fn receive_text(client: WebsocketClient, timeout: Int) -> Result(String, Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "close")
fn close(client: WebsocketClient) -> Nil

@external(erlang, "beryl_mist_transport_test_ffi", "http_get")
fn http_get(port: Int, path: String) -> Result(Int, Nil)

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

// The HTTP fallback replies with a distinctive 418 so routing to the fallback
// is observable from the test client.
fn start_server(channels: beryl.Channels) -> #(Int, process.Pid) {
  start_server_with_config(channels, ewe_transport.default_config("/socket"))
}

fn start_server_with_config(
  channels: beryl.Channels,
  config: ewe_transport.TransportConfig(assigns),
) -> #(Int, process.Pid) {
  let port_subject = process.new_subject()
  let http_fallback = fn(_request) {
    response.new(418)
    |> response.set_body(ewe.Empty)
  }
  let assert Ok(server) =
    ewe_transport.handler(channels, config, http_fallback)
    |> ewe.new
    |> ewe.listening(port: 0)
    |> ewe.bind(interface: "127.0.0.1")
    |> ewe.on_start(fn(_scheme, address) {
      process.send(port_subject, address.port)
    })
    |> ewe.start
  let assert Ok(port) = process.receive(port_subject, 1000)
  #(port, server.pid)
}

fn start_limited_server() -> #(Int, process.Pid) {
  let assert Ok(channels) =
    beryl.start(
      beryl.Config(
        ..beryl.config(wire.phoenix_codec()),
        max_connections_per_ip: 1,
      ),
    )
  start_server(channels)
}

fn start_frame_limited_server() -> #(Int, process.Pid) {
  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_inbound_frame_bytes(max_bytes: 32),
    )
  start_server(channels)
}

fn start_channels() -> beryl.Channels {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  channels
}

pub fn handler_routes_websocket_upgrade_to_upgrade_test() {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // A WebSocket upgrade to the configured path completes the handshake (101).
  let assert Ok(client) = connect_websocket(port, "/socket")
  close(client)

  stop_supervisor(server_pid)
}

pub fn handler_routes_http_request_to_fallback_test() {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // A normal HTTP request to the socket path hits the fallback, not the upgrade.
  http_get(port, "/socket")
  |> should.equal(Ok(418))

  stop_supervisor(server_pid)
}

pub fn handler_routes_non_matching_path_to_fallback_test() {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // A request to an unrelated path falls through to the fallback handler.
  http_get(port, "/health")
  |> should.equal(Ok(418))

  stop_supervisor(server_pid)
}

pub fn handler_routes_websocket_on_other_path_to_fallback_test() {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // A WebSocket upgrade to a non-matching path is not upgraded (no 101),
  // so the client handshake fails and routing falls back to HTTP.
  connect_websocket(port, "/not-socket")
  |> should.equal(Error(Nil))

  stop_supervisor(server_pid)
}

pub fn handler_rejects_disallowed_origin_and_allows_allowed_origin_test() {
  let channels = start_channels()
  let config =
    ewe_transport.default_config("/socket")
    |> ewe_transport.with_allowed_origins(["https://app.example.com"])
  let #(port, server_pid) = start_server_with_config(channels, config)

  websocket_upgrade_status_with_origin(
    port,
    "/socket",
    "https://evil.example.com",
  )
  |> should.equal(Ok(403))

  let assert Ok(client) =
    connect_websocket_with_origin(port, "/socket", "https://app.example.com")
  close(client)
  stop_supervisor(server_pid)
}

pub fn handler_rejects_connections_over_per_ip_limit_test() {
  let #(port, server_pid) = start_limited_server()

  let assert Ok(client) = connect_websocket(port, "/socket")

  websocket_upgrade_status(port, "/socket")
  |> should.equal(Ok(429))

  close(client)
  process.sleep(50)

  let assert Ok(next_client) = connect_websocket(port, "/socket")
  close(next_client)
  stop_supervisor(server_pid)
}

pub fn handler_closes_socket_on_oversized_text_frame_test() {
  let #(port, server_pid) = start_frame_limited_server()
  let assert Ok(client) = connect_websocket(port, "/socket")

  let oversized_frame = string.repeat("a", 64)
  let assert Ok(_) = send_text(client, oversized_frame)
  receive_text(client, 200)
  |> should.equal(Error(Nil))

  close(client)
  stop_supervisor(server_pid)
}
