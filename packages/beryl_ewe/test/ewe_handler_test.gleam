//// Integration tests for the combined `ewe_transport.handler`.
////
//// These spin up a real Ewe listener so we can verify how the composed
//// handler routes WebSocket upgrades versus plain HTTP requests. They reuse a
//// server-agnostic raw-TCP WebSocket client FFI.

import beryl
import beryl/channel
import beryl/supervisor
import beryl/wire
import beryl_ewe as ewe_transport
import ewe
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleeunit/should

type WebsocketClient

@external(erlang, "beryl_ewe_transport_test_ffi", "connect_websocket")
fn connect_websocket(port: Int, path: String) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "connect_websocket_with_origin")
fn connect_websocket_with_origin(
  port: Int,
  path: String,
  origin: String,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "websocket_upgrade_status_with_origin")
fn websocket_upgrade_status_with_origin(
  port: Int,
  path: String,
  origin: String,
) -> Result(Int, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "websocket_upgrade_status")
fn websocket_upgrade_status(port: Int, path: String) -> Result(Int, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "send_text")
fn send_text(
  client: WebsocketClient,
  text: String,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "send_binary")
fn send_binary(
  client: WebsocketClient,
  data: BitArray,
) -> Result(WebsocketClient, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "attach_transport_events")
fn attach_transport_events() -> Dynamic

@external(erlang, "beryl_ewe_transport_test_ffi", "detach_transport_events")
fn detach_transport_events(handler_id: Dynamic) -> Nil

@external(erlang, "beryl_ewe_transport_test_ffi", "receive_upgrade_event")
fn receive_upgrade_event(timeout: Int) -> Result(#(String, String), Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "receive_frame_event")
fn receive_frame_event(
  timeout: Int,
) -> Result(#(String, String, String, Int), Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "receive_message_event")
fn receive_message_event(timeout: Int) -> Result(#(String, String, String), Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "receive_text")
fn receive_text(client: WebsocketClient, timeout: Int) -> Result(String, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "close")
fn close(client: WebsocketClient) -> Nil

@external(erlang, "beryl_ewe_transport_test_ffi", "http_get")
fn http_get(port: Int, path: String) -> Result(Int, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "stop_supervisor")
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
    start_supervised(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_connections_per_ip(max_connections: 1),
    )
  start_server(channels)
}

fn start_frame_limited_server() -> #(Int, process.Pid) {
  let assert Ok(channels) =
    start_supervised(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_inbound_frame_bytes(max_bytes: 32),
    )
  start_server(channels)
}

fn start_channels() -> beryl.Channels {
  let assert Ok(channels) = start_supervised(beryl.config(wire.phoenix_codec()))
  channels
}

fn register_telemetry_channel(channels: beryl.Channels) -> Nil {
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
    |> channel.with_handle_in(fn(_event, _payload, socket) {
      channel.NoReply(socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)
  Nil
}

pub fn telemetry_preserves_decoded_text_and_binary_message_kinds_test() {
  let assert Ok(channels) =
    start_supervised(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_telemetry,
    )
  register_telemetry_channel(channels)
  let #(port, server_pid) = start_server(channels)
  let handler_id = attach_transport_events()
  let assert Ok(client) = connect_websocket(port, "/socket")
  receive_upgrade_event(1000)
  |> should.equal(Ok(#("ewe", "success")))

  let join = "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]"
  let assert Ok(client) = send_text(client, join)
  let assert Ok(_) = receive_text(client, 1000)
  receive_frame_event(1000)
  |> should.equal(Ok(#("ewe", "text", "routed", string.byte_size(join))))

  let text_event = "[\"join-ref\",\"text-ref\",\"room:lobby\",\"ping\",{}]"
  let assert Ok(client) = send_text(client, text_event)
  receive_frame_event(1000)
  |> should.equal(Ok(#("ewe", "text", "routed", string.byte_size(text_event))))
  receive_message_event(1000)
  |> should.equal(Ok(#("text", "handled", "no_reply")))

  let binary_event = <<
    0,
    8,
    10,
    10,
    4,
    "join-ref":utf8,
    "binary-ref":utf8,
    "room:lobby":utf8,
    "ping":utf8,
    1,
  >>
  let assert Ok(client) = send_binary(client, binary_event)
  receive_frame_event(1000)
  |> should.equal(
    Ok(#("ewe", "binary", "routed", bit_array.byte_size(binary_event))),
  )
  receive_message_event(1000)
  |> should.equal(Ok(#("binary", "handled", "no_reply")))

  close(client)
  detach_transport_events(handler_id)
  stop_supervisor(server_pid)
}

pub fn telemetry_reports_matched_upgrades_and_frames_once_test() {
  let assert Ok(channels) =
    start_supervised(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_telemetry,
    )
  let config =
    ewe_transport.default_config("/socket")
    |> ewe_transport.with_allowed_origins(["https://app.example.com"])
  let #(port, server_pid) = start_server_with_config(channels, config)
  let handler_id = attach_transport_events()

  websocket_upgrade_status_with_origin(
    port,
    "/socket",
    "https://evil.example.com",
  )
  |> should.equal(Ok(403))
  receive_upgrade_event(1000)
  |> should.equal(Ok(#("ewe", "origin_rejected")))

  let assert Ok(client) =
    connect_websocket_with_origin(port, "/socket", "https://app.example.com")
  receive_upgrade_event(1000)
  |> should.equal(Ok(#("ewe", "success")))

  let heartbeat = "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]"
  let assert Ok(client) = send_text(client, heartbeat)
  receive_frame_event(1000)
  |> should.equal(Ok(#("ewe", "text", "routed", string.byte_size(heartbeat))))

  let assert Ok(client) = send_binary(client, <<1, 2, 3>>)
  receive_frame_event(1000)
  |> should.equal(Ok(#("ewe", "binary", "decode_failed", 3)))

  receive_upgrade_event(0)
  |> should.equal(Error(Nil))
  receive_frame_event(0)
  |> should.equal(Error(Nil))

  close(client)
  detach_transport_events(handler_id)
  stop_supervisor(server_pid)
}

pub fn telemetry_reports_oversized_and_rate_limited_frames_test() {
  let assert Ok(limited_channels) =
    start_supervised(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_inbound_frame_bytes(max_bytes: 4)
      |> beryl.with_telemetry,
    )
  let handler_id = attach_transport_events()
  let #(limited_port, limited_server_pid) = start_server(limited_channels)
  let assert Ok(limited_client) = connect_websocket(limited_port, "/socket")
  let assert Ok(#("ewe", "success")) = receive_upgrade_event(1000)
  let assert Ok(_) = send_text(limited_client, "12345")
  receive_frame_event(1000)
  |> should.equal(Ok(#("ewe", "text", "oversized", 5)))
  close(limited_client)
  stop_supervisor(limited_server_pid)
  detach_transport_events(handler_id)

  let assert Ok(rate_channels) =
    start_supervised(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 1, burst: 1)
      |> beryl.with_telemetry,
    )
  let handler_id = attach_transport_events()
  let #(rate_port, rate_server_pid) = start_server(rate_channels)
  let assert Ok(rate_client) = connect_websocket(rate_port, "/socket")
  let assert Ok(#("ewe", "success")) = receive_upgrade_event(1000)
  let heartbeat = "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]"
  let assert Ok(rate_client) = send_text(rate_client, heartbeat)
  let assert Ok(#("ewe", "text", "routed", _)) = receive_frame_event(1000)
  let assert Ok(rate_client) = send_text(rate_client, heartbeat)
  receive_frame_event(1000)
  |> should.equal(
    Ok(#("ewe", "text", "rate_limited", string.byte_size(heartbeat))),
  )
  close(rate_client)
  detach_transport_events(handler_id)
  stop_supervisor(rate_server_pid)
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

pub fn handler_default_rejects_cross_origin_upgrade_test() {
  // The default config uses the SameOrigin policy, so a browser upgrade whose
  // Origin does not match the request Host is rejected before the handshake.
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  websocket_upgrade_status_with_origin(
    port,
    "/socket",
    "https://evil.example.com",
  )
  |> should.equal(Ok(403))

  stop_supervisor(server_pid)
}

pub fn handler_default_allows_same_origin_upgrade_test() {
  // A same-origin browser upgrade (Origin authority matches the Host authority
  // `127.0.0.1:<port>`) is admitted under the default SameOrigin policy.
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let assert Ok(client) = connect_websocket_with_origin(port, "/socket", origin)
  close(client)

  stop_supervisor(server_pid)
}

pub fn handler_default_allows_absent_origin_upgrade_test() {
  // Non-browser clients omit the Origin header entirely; the SameOrigin policy
  // admits them (they are not subject to the browser same-origin model).
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  let assert Ok(client) = connect_websocket(port, "/socket")
  close(client)

  stop_supervisor(server_pid)
}

pub fn handler_allow_all_origins_admits_cross_origin_test() {
  // Explicit opt-out: with_allow_all_origins restores the pre-1.0 allow-all
  // behaviour for apps that intentionally accept cross-origin sockets.
  let channels = start_channels()
  let config =
    ewe_transport.default_config("/socket")
    |> ewe_transport.with_allow_all_origins()
  let #(port, server_pid) = start_server_with_config(channels, config)

  let assert Ok(client) =
    connect_websocket_with_origin(port, "/socket", "https://evil.example.com")
  close(client)

  stop_supervisor(server_pid)
}

pub fn handler_rejects_unsupported_protocol_version_test() {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // Phoenix V1 clients are rejected at the handshake instead of connecting
  // successfully and having every frame silently fail to decode.
  websocket_upgrade_status(port, "/socket?vsn=1.0.0")
  |> should.equal(Ok(403))

  // The V2 version Phoenix JS sends is accepted, as is omitting vsn.
  let assert Ok(v2_client) = connect_websocket(port, "/socket?vsn=2.0.0")
  close(v2_client)
  let assert Ok(bare_client) = connect_websocket(port, "/socket")
  close(bare_client)

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

pub fn handler_allows_unlimited_connections_when_limit_is_zero_test() {
  // The default config leaves `max_connections_per_ip` at 0 (unlimited), so
  // multiple concurrent connections from the same peer IP are all admitted.
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  let assert Ok(first) = connect_websocket(port, "/socket")
  let assert Ok(second) = connect_websocket(port, "/socket")
  let assert Ok(third) = connect_websocket(port, "/socket")

  close(first)
  close(second)
  close(third)
  stop_supervisor(server_pid)
}

pub fn handler_sheds_message_flood_at_the_edge_test() {
  let assert Ok(channels) =
    start_supervised(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 1, burst: 2),
    )
  let #(port, server_pid) = start_server(channels)
  let assert Ok(client) = connect_websocket(port, "/socket")

  // Flood heartbeats: only the burst allowance may produce replies. The
  // rest are shed by the connection process before reaching the
  // coordinator.
  send_heartbeats(client, 10)
  let replies = count_replies(client, 0)
  { replies <= 2 } |> should.be_true
  { replies >= 1 } |> should.be_true

  close(client)
  stop_supervisor(server_pid)
}

fn send_heartbeats(client: WebsocketClient, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let assert Ok(_) =
        send_text(client, "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]")
      send_heartbeats(client, remaining - 1)
    }
  }
}

fn count_replies(client: WebsocketClient, count: Int) -> Int {
  case receive_text(client, 200) {
    Ok(_) -> count_replies(client, count + 1)
    Error(Nil) -> count
  }
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

/// Start a supervised channel system for tests.
///
/// beryl exposes no public unsupervised start, so tests stand up a real
/// supervision tree the way an application would.
fn start_supervised(
  config: beryl.Config,
) -> Result(beryl.Channels, actor.StartError) {
  let supervised = supervisor.config(config)
  use _root <- result.map(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervisor.start(supervised))
    |> static_supervisor.start(),
  )
  supervisor.channels(supervised)
}
