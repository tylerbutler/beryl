//// Integration tests for the combined `ewe_transport.handler`.
////
//// These spin up a real Ewe listener so we can verify how the composed
//// handler routes WebSocket upgrades versus plain HTTP requests. They reuse a
//// server-agnostic raw-TCP WebSocket client FFI.

import app_test_helpers as h
import beryl
import beryl/socket
import beryl/transport/server
import beryl/wire
import beryl_ewe as ewe_transport
import ewe
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option
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
fn start_server(channels: beryl.Sockets) -> #(Int, process.Pid) {
  start_server_with_config(channels, server.default_config("/socket"))
}

fn start_server_with_config(
  channels: beryl.Sockets,
  config: server.TransportConfig(ewe.Connection),
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
  let channels =
    start_app_system(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_connections_per_ip(max_connections: 1),
    )
  start_server(channels)
}

fn start_frame_limited_server() -> #(Int, process.Pid) {
  let channels =
    start_app_system(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_inbound_frame_bytes(max_bytes: 32),
    )
  start_server(channels)
}

fn start_channels() -> beryl.Sockets {
  start_app_system(beryl.config(wire.phoenix_codec()))
}

/// Start a minimal app-side dispatch system for transport-edge tests. The
/// `update` never dispatches anything — these tests exercise upgrade, origin,
/// connection-limit, frame-size, and flood-shedding behaviour, not routing.
fn start_app_system(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start(config, init: fn(_info) { #(Nil, []) }, update: fn(model, _ev) {
      socket.Next(model, [])
    })
  channels
}

fn start_telemetry_system() -> beryl.Sockets {
  let assert Ok(channels) =
    h.start(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_telemetry,
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, socket_event) {
        case socket_event {
          socket.Join(_, _, ref) ->
            socket.Next(model, [socket.AcceptJoin(ref, option.None)])
          _ -> socket.Next(model, [])
        }
      },
    )
  channels
}

pub fn telemetry_preserves_decoded_text_and_binary_message_kinds_test() {
  let channels = start_telemetry_system()
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
  let assert Ok(Nil) = beryl.stop(channels)
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
    server.default_config("/socket")
    |> server.with_allowed_origins(["https://app.example.com"])
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
    server.default_config("/socket")
    |> server.with_allow_all_origins()
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

pub fn handler_sheds_frame_flood_at_the_edge_test() {
  let channels =
    start_app_system(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_frame_rate(per_second: 1, burst: 2),
    )
  let #(port, server_pid) = start_server(channels)
  let assert Ok(client) = connect_websocket(port, "/socket")

  // Flood heartbeats: only the burst allowance may produce replies. The
  // rest are shed by the connection process, pre-decode, before reaching
  // the runtime — `with_frame_rate` alone accomplishes this with no
  // `with_message_rate` configured.
  send_heartbeats(client, 10)
  let replies = count_replies(client, 0)
  { replies <= 2 } |> should.be_true
  { replies >= 1 } |> should.be_true

  close(client)
  stop_supervisor(server_pid)
}

pub fn handler_message_rate_alone_does_not_shed_frames_at_the_edge_test() {
  // Regression: `with_message_rate` governs the runtime bucket only. A
  // heartbeat flood still gets shed (the runtime's message limiter catches
  // it after decode), but the two settings are independent — this proves
  // `with_message_rate` is not silently doing edge-level frame shedding.
  let channels =
    start_app_system(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 1, burst: 2),
    )
  let #(port, server_pid) = start_server(channels)
  let assert Ok(client) = connect_websocket(port, "/socket")

  send_heartbeats(client, 10)
  let replies = count_replies(client, 0)
  { replies <= 2 } |> should.be_true
  { replies >= 1 } |> should.be_true

  close(client)
  stop_supervisor(server_pid)
}

pub fn handler_frame_rate_counts_malformed_frames_test() {
  // Regression: the frame-rate bucket counts every complete inbound frame
  // before decoding, so a malformed frame consumes a token the same as a
  // well-formed one — a single-token burst spent on garbage leaves no
  // token for a following valid heartbeat.
  let channels =
    start_app_system(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_frame_rate(per_second: 1, burst: 1),
    )
  let #(port, server_pid) = start_server(channels)
  let assert Ok(client) = connect_websocket(port, "/socket")

  let assert Ok(_) = send_text(client, "not-valid-json")
  let assert Ok(_) =
    send_text(client, "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]")

  receive_text(client, 200) |> should.equal(Error(Nil))

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

pub fn runtime_death_closes_the_connection_test() {
  let assert Ok(channels) =
    h.start(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          socket.Join(_, _, ref) ->
            socket.Next(model, [
              socket.AcceptJoin(
                ref,
                option.Some(json.object([#("joined", json.bool(True))])),
              ),
            ])
          _ -> socket.Next(model, [])
        }
      },
    )
  let #(port, server_pid) = start_server(channels)

  let assert Ok(client) = connect_websocket(port, "/socket")
  let assert Ok(client) =
    send_text(client, "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]")
  let assert Ok(_join_reply) = receive_text(client, 1000)

  // Kill the runtime that accepted the connection. The transport monitors the
  // owning runtime and closes the connection rather than leaving a zombie.
  let assert Ok(runtime) = beryl.app_runtime_pid(channels)
  process.kill(runtime)

  receive_text(client, 2000)
  |> should.equal(Error(Nil))

  stop_supervisor(server_pid)
}

// Socket-level connect/auth hook — on_connect metadata reaches init

fn auth_query(req, name: String) -> Result(String, Nil) {
  case request.get_query(req) {
    Ok(params) -> list.key_find(params, name)
    Error(_) -> Error(Nil)
  }
}

pub fn on_connect_seeds_metadata_visible_in_connect_info_test() {
  // `with_on_connect` returns ordered string metadata; it lands verbatim in
  // `ConnectInfo.seed.metadata` for an app-dispatch system's `init`.
  // Duplicate keys must be preserved — the runtime must not deduplicate them.
  let seeds = process.new_subject()
  let assert Ok(channels) =
    h.start(
      beryl.config(wire.phoenix_codec()),
      init: fn(info: socket.ConnectInfo(Nil)) {
        process.send(seeds, info.seed)
        #(Nil, [])
      },
      update: fn(model, _ev) { socket.Next(model, []) },
    )

  let config =
    server.default_config("/socket")
    |> server.with_on_connect(fn(req) {
      auth_query(req, "token")
      |> result.map(fn(token) { [#("user", token), #("user", token)] })
      |> result.map_error(fn(_) { server.ConnectRejected })
    })
  let #(port, server_pid) = start_server_with_config(channels, config)

  let assert Ok(client) = connect_websocket(port, "/socket?token=alice")
  let assert Ok(seed) = process.receive(seeds, 1000)

  // Order and duplicate keys are preserved verbatim, not deduplicated.
  seed.metadata |> should.equal([#("user", "alice"), #("user", "alice")])
  seed.path |> should.equal("/socket")

  close(client)
  stop_supervisor(server_pid)
}
