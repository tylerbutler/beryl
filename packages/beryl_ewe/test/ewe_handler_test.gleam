//// Integration tests for the combined `ewe_transport.handler`.
////
//// These spin up a real Ewe listener so we can verify how the composed
//// handler routes WebSocket upgrades versus plain HTTP requests. They reuse a
//// server-agnostic raw-TCP WebSocket client FFI.

import alpacki
import app_test_helper
import beryl
import beryl/snapshot
import beryl/socket
import beryl/transport/server
import beryl/wire
import beryl/wire/codec
import beryl_ewe as ewe_transport
import ewe
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
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
import glisten/socket as tcp_socket
import glisten/tcp
import unitest

type WebsocketClient

type TransportEventHandler

@external(erlang, "beryl_ewe_transport_test_ffi", "connect_tcp")
fn connect_tcp(port: Int) -> Result(tcp_socket.Socket, tcp_socket.SocketReason)

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
fn attach_transport_events() -> TransportEventHandler

@external(erlang, "beryl_ewe_transport_test_ffi", "detach_transport_events")
fn detach_transport_events(handler_id: TransportEventHandler) -> Nil

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

@external(erlang, "beryl_ewe_transport_test_ffi", "receive_binary")
fn receive_binary(
  client: WebsocketClient,
  timeout: Int,
) -> Result(BitArray, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "close")
fn close(client: WebsocketClient) -> Nil

@external(erlang, "beryl_ewe_transport_test_ffi", "http_get")
fn http_get(port: Int, path: String) -> Result(Int, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

@external(erlang, "beryl_ewe_transport_test_ffi", "suspend_server_peer")
fn suspend_server_peer(client: WebsocketClient) -> Result(process.Pid, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "outbound_queue_usage")
fn outbound_queue_usage(pid: process.Pid) -> #(Int, Int)

// Runtime log capture distinguishes edge shedding from runtime shedding.
type CapturedLog {
  CapturedLog(message: String, metadata: dict.Dict(String, String))
}

@external(erlang, "beryl_log_capture", "stop")
fn stop_capture() -> Nil

@external(erlang, "beryl_log_capture", "with_capture")
fn with_capture(action: fn() -> a) -> a

fn captured_decoder() -> decode.Decoder(CapturedLog) {
  use message <- decode.field(1, decode.string)
  use metadata <- decode.field(2, decode.dict(decode.string, decode.string))
  decode.success(CapturedLog(message:, metadata:))
}

fn coerce_captured(value: dynamic.Dynamic) -> CapturedLog {
  case decode.run(value, captured_decoder()) {
    Ok(captured) -> captured
    Error(_) -> CapturedLog(message: "", metadata: dict.new())
  }
}

fn captured_selector() -> process.Selector(CapturedLog) {
  process.new_selector()
  |> process.select_record(atom.create("captured_log"), 2, coerce_captured)
}

fn drain_captured(selector: process.Selector(CapturedLog)) -> Nil {
  case process.selector_receive(selector, 0) {
    Ok(_) -> drain_captured(selector)
    Error(Nil) -> Nil
  }
}

fn receive_log(
  selector: process.Selector(CapturedLog),
  message: String,
  attempts: Int,
) -> Result(CapturedLog, Nil) {
  case attempts <= 0 {
    True -> Error(Nil)
    False ->
      case process.selector_receive(selector, 500) {
        Ok(captured) ->
          case captured.message == message {
            True -> Ok(captured)
            False -> receive_log(selector, message, attempts - 1)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

// The HTTP fallback replies with a distinctive 418 so routing to the fallback
// is observable from the test client.
fn start_server(channels: beryl.Sockets) -> #(Int, process.Pid) {
  start_server_with_config(channels, server.default_config("/socket"))
}

fn start_server_with_config(
  channels: beryl.Sockets,
  config: server.TransportConfig(ewe.Connection),
) -> #(Int, process.Pid) {
  let http_fallback = fn(_request) {
    response.new(418)
    |> response.set_body(ewe.Empty)
  }
  let assert Ok(server) =
    ewe_transport.handler(channels, config, http_fallback)
    |> ewe.new
    |> ewe.listening_random
    |> ewe.bind(to: "127.0.0.1")
    |> ewe.quiet
    |> ewe.start
  let assert ewe.TcpSocketAddress(_, port) = server.data
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
    app_test_helper.start(
      config,
      init: fn(_info) { #(Nil, []) },
      update: fn(model, _event) { socket.Next(model, []) },
    )
  channels
}

fn start_telemetry_system() -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_telemetry,
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, socket_event) {
        case socket_event {
          socket.Join(_, _, ref) ->
            socket.Next(model, [socket.AcceptJoin(ref, option.None)])
          socket.Message(_, _, _, _)
          | socket.Binary(_, _)
          | socket.Closed(_, _)
          | socket.Info(_) -> socket.Next(model, [])
        }
      },
    )
  channels
}

pub fn telemetry_preserves_decoded_text_and_binary_message_kinds_test() -> Nil {
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
  beryl.stop(channels) |> should.equal(Ok(Nil))
}

pub fn handler_routes_websocket_upgrade_to_upgrade_test() -> Nil {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // A WebSocket upgrade to the configured path completes the handshake (101).
  let assert Ok(client) = connect_websocket(port, "/socket")
  close(client)

  stop_supervisor(server_pid)
}

pub fn handler_http2_connect_same_origin_nondefault_port_test() -> Nil {
  check_http2_connect("127.0.0.1", "127.0.0.1", 0, "/socket", "200")
}

pub fn handler_http2_connect_same_origin_ipv6_authority_test() -> Nil {
  // Authority parsing is independent of the TCP peer: no IPv6 listener needed.
  check_http2_connect("[::1]", "[::1]", 0, "/socket", "200")
}

pub fn handler_http2_connect_cross_origin_rejected_test() -> Nil {
  check_http2_connect("127.0.0.1", "evil.example.com", 0, "/socket", "403")
}

pub fn handler_http2_connect_origin_port_mismatch_rejected_test() -> Nil {
  check_http2_connect("127.0.0.1", "127.0.0.1", -1, "/socket", "403")
}

pub fn handler_http2_connect_other_path_uses_fallback_test() -> Nil {
  check_http2_connect("127.0.0.1", "127.0.0.1", 0, "/not-socket", "418")
}

const heartbeat_reply = "[null,\"hb\",\"phoenix\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]"

fn check_http2_connect(
  host: String,
  origin_host: String,
  port_offset: Int,
  path: String,
  expected_status: String,
) -> Nil {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)
  let outcome = {
    use client <- result.try(connect_tcp(port) |> result.map_error(TcpFailure))
    let outcome =
      http2_connect(
        client,
        host <> ":" <> int.to_string(port),
        "http://" <> origin_host <> ":" <> int.to_string(port + port_offset),
        path,
      )
    let closed = tcp.close(client) |> result.map_error(TcpFailure)
    // Close even if the exchange failed; keep its original diagnostic.
    use value <- result.try(outcome)
    use _ <- result.try(closed)
    Ok(value)
  }
  stop_supervisor(server_pid)
  let stopped = beryl.stop(channels)
  let expected_reply = case expected_status {
    "200" -> heartbeat_reply
    _ -> ""
  }
  outcome |> should.equal(Ok(#(expected_status, expected_reply)))
  stopped |> should.equal(Ok(Nil))
}

type Http2TestError {
  TcpFailure(tcp_socket.SocketReason)
  HpackFailure(alpacki.DecodeError)
  UnexpectedHttp2Frame(BitArray)
  InvalidHttp2Response(BitArray)
  Http2FrameLimit
}

fn http2_connect(
  client: tcp_socket.Socket,
  authority: String,
  origin: String,
  path: String,
) -> Result(#(String, String), Http2TestError) {
  let settings = http2_frame(4, 0, 0, <<>>)
  use _ <- result.try(
    http2_send(client, <<
      "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8,
      settings:bits,
    >>),
  )
  // RFC 8441: do not send extended CONNECT until the server advertises it.
  use _ <- result.try(http2_wait(client, 4, 16))
  let fields =
    [
      #(":method", "CONNECT"),
      #(":protocol", "websocket"),
      #(":scheme", "http"),
      #(":path", path),
      #(":authority", authority),
      #("sec-websocket-version", "13"),
      #("origin", origin),
    ]
    |> list.map(fn(field) {
      alpacki.HeaderField(
        bit_array.from_string(field.0),
        bit_array.from_string(field.1),
        alpacki.WithoutIndexing,
      )
    })
  // Deliberately no Host, Upgrade, Connection, or sec-websocket-key headers.
  let #(block, _) =
    alpacki.encode_header_block(fields, alpacki.new_dynamic(4096), False)
  use _ <- result.try(http2_send(client, http2_frame(1, 4, 1, block)))
  use block <- result.try(http2_wait(client, 1, 16))
  use decoded <- result.try(
    alpacki.decode_header_block(block, alpacki.new_dynamic(4096))
    |> result.map_error(HpackFailure),
  )
  use status <- result.try(case decoded.remaining {
    <<>> ->
      list.key_find(decoded.headers, <<":status":utf8>>)
      |> result.replace_error(InvalidHttp2Response(block))
    _ -> Error(InvalidHttp2Response(block))
  })
  use status <- result.try(
    bit_array.to_string(status)
    |> result.replace_error(InvalidHttp2Response(status)),
  )
  case status {
    "200" -> {
      let heartbeat = "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]"
      // A masked, final text frame. The fixed zero mask is valid for this
      // deterministic test fixture, not for a production WebSocket client.
      let frame = <<
        0x81,
        1:1,
        string.byte_size(heartbeat):7,
        0:32,
        heartbeat:utf8,
      >>
      use _ <- result.try(http2_send(client, http2_frame(0, 0, 1, frame)))
      use reply <- result.try(http2_heartbeat_reply(client, <<>>, 16))
      Ok(#(status, reply))
    }
    _ -> Ok(#(status, ""))
  }
}

fn http2_frame(
  kind: Int,
  flags: Int,
  stream: Int,
  payload: BitArray,
) -> BitArray {
  <<bit_array.byte_size(payload):24, kind, flags, stream:32, payload:bits>>
}

fn http2_send(
  client: tcp_socket.Socket,
  data: BitArray,
) -> Result(Nil, Http2TestError) {
  tcp.send(client, bytes_tree.from_bit_array(data))
  |> result.map_error(TcpFailure)
}

// This fixture expects one small END_HEADERS block, unpadded DATA, and stream 1.
// Exact-length passive reads handle TCP splitting/coalescing without a mailbox.
// Bound both frame size and count; every receive also has a one-second timeout.
fn http2_wait(
  client: tcp_socket.Socket,
  wanted: Int,
  remaining: Int,
) -> Result(BitArray, Http2TestError) {
  use <- bool.guard(remaining <= 0, Error(Http2FrameLimit))
  use header <- result.try(
    tcp.receive_timeout(client, 9, 1000) |> result.map_error(TcpFailure),
  )
  use frame <- result.try(case header {
    <<length:24, kind, flags, 0:1, stream:31>> if length <= 16_384 -> {
      let payload = case length {
        0 -> Ok(<<>>)
        _ ->
          tcp.receive_timeout(client, length, 1000)
          |> result.map_error(TcpFailure)
      }
      result.map(payload, fn(payload) { #(kind, flags, stream, payload) })
    }
    _ -> Error(UnexpectedHttp2Frame(header))
  })
  case frame {
    #(4, 0, 0, payload) -> {
      use _ <- result.try(http2_send(client, http2_frame(4, 1, 0, <<>>)))
      case wanted == 4 && enables_connect(payload) {
        True -> Ok(payload)
        False -> http2_wait(client, wanted, remaining - 1)
      }
    }
    #(4, 1, 0, <<>>) | #(8, 0, _, _) ->
      http2_wait(client, wanted, remaining - 1)
    #(6, 0, 0, payload) -> {
      use _ <- result.try(http2_send(client, http2_frame(6, 1, 0, payload)))
      http2_wait(client, wanted, remaining - 1)
    }
    #(1, 4, 1, payload) | #(1, 5, 1, payload) if wanted == 1 -> Ok(payload)
    #(0, 0, 1, payload) if wanted == 0 -> Ok(payload)
    _ -> Error(UnexpectedHttp2Frame(header))
  }
}

fn enables_connect(settings: BitArray) -> Bool {
  case settings {
    <<8:16, 1:32, _:bits>> -> True
    <<_:16, _:32, rest:bits>> -> enables_connect(rest)
    _ -> False
  }
}

fn http2_heartbeat_reply(
  client: tcp_socket.Socket,
  buffered: BitArray,
  remaining: Int,
) -> Result(String, Http2TestError) {
  case buffered {
    <<0x81, 0:1, length:7, text:bytes-size(length)>> if length < 126 ->
      bit_array.to_string(text)
      |> result.replace_error(InvalidHttp2Response(buffered))
    _ if remaining <= 0 -> Error(Http2FrameLimit)
    _ -> {
      use data <- result.try(http2_wait(client, 0, 16))
      http2_heartbeat_reply(client, <<buffered:bits, data:bits>>, remaining - 1)
    }
  }
}

pub fn handler_routes_http_request_to_fallback_test() -> Nil {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // A normal HTTP request to the socket path hits the fallback, not the upgrade.
  http_get(port, "/socket")
  |> should.equal(Ok(418))

  stop_supervisor(server_pid)
}

pub fn handler_routes_non_matching_path_to_fallback_test() -> Nil {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // A request to an unrelated path falls through to the fallback handler.
  http_get(port, "/health")
  |> should.equal(Ok(418))

  stop_supervisor(server_pid)
}

pub fn handler_routes_websocket_on_other_path_to_fallback_test() -> Nil {
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  // A WebSocket upgrade to a non-matching path is not upgraded (no 101),
  // so the client handshake fails and routing falls back to HTTP.
  connect_websocket(port, "/not-socket")
  |> should.equal(Error(Nil))

  stop_supervisor(server_pid)
}

pub fn handler_rejects_disallowed_origin_and_allows_allowed_origin_test() -> Nil {
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

pub fn handler_default_rejects_cross_origin_upgrade_test() -> Nil {
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

pub fn handler_default_allows_same_origin_upgrade_test() -> Nil {
  // A same-origin browser upgrade (Origin authority matches the Host authority
  // `127.0.0.1:<port>`) is admitted under the default SameOrigin policy.
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let assert Ok(client) = connect_websocket_with_origin(port, "/socket", origin)
  close(client)

  stop_supervisor(server_pid)
}

pub fn handler_default_allows_absent_origin_upgrade_test() -> Nil {
  // Non-browser clients omit the Origin header entirely; the SameOrigin policy
  // admits them (they are not subject to the browser same-origin model).
  let channels = start_channels()
  let #(port, server_pid) = start_server(channels)

  let assert Ok(client) = connect_websocket(port, "/socket")
  close(client)

  stop_supervisor(server_pid)
}

pub fn handler_allow_all_origins_admits_cross_origin_test() -> Nil {
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

pub fn handler_rejects_unsupported_protocol_version_test() -> Nil {
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

pub fn handler_rejects_connections_over_per_ip_limit_test() -> Nil {
  let #(port, server_pid) = start_limited_server()

  let assert Ok(client) = connect_websocket(port, "/socket")

  websocket_upgrade_status(port, "/socket")
  |> should.equal(Ok(429))

  close(client)
  wait_for_upgrade(port, 1000) |> should.equal(Ok(101))
  stop_supervisor(server_pid)
}

pub fn abrupt_tcp_close_after_upgrade_releases_per_ip_slot_test() -> Nil {
  let #(port, server_pid) = start_limited_server()

  // This helper closes TCP immediately after reading 101: no WebSocket close
  // frame or heartbeat synchronizes with Ewe's initialization/ownership.
  websocket_upgrade_status(port, "/socket") |> should.equal(Ok(101))
  list.repeat(Nil, 5)
  |> list.each(fn(_) { wait_for_upgrade(port, 1000) |> should.equal(Ok(101)) })

  stop_supervisor(server_pid)
}

fn wait_for_upgrade(port: Int, remaining_ms: Int) -> Result(Int, Nil) {
  case websocket_upgrade_status(port, "/socket") {
    Ok(429) if remaining_ms > 0 -> {
      process.sleep(10)
      wait_for_upgrade(port, remaining_ms - 10)
    }
    Ok(status) -> Ok(status)
    Error(Nil) -> Error(Nil)
  }
}

pub fn handler_allows_unlimited_connections_when_limit_is_zero_test() -> Nil {
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

pub fn handler_sheds_frame_flood_at_the_edge_test() -> Nil {
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

pub fn handler_message_rate_alone_does_not_shed_frames_at_the_edge_test() -> Nil {
  use <- unitest.tag("serial")
  // Regression: `with_message_rate` governs the runtime bucket only. A
  // heartbeat flood still gets shed (the runtime's message limiter catches
  // it after decode), but the two settings are independent — this proves
  // `with_message_rate` is not silently doing edge-level frame shedding.
  let channels =
    start_app_system(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 1, burst: 2)
      |> beryl.with_logging(beryl.logging_config(
        level: beryl.DebugLevel,
        include_payloads: False,
      )),
    )
  let #(port, server_pid) = start_server(channels)
  let assert Ok(client) = connect_websocket(port, "/socket")
  use <- with_capture()
  let selector = captured_selector()
  drain_captured(selector)

  send_heartbeats(client, 10)
  let replies = count_replies(client, 0)
  { replies <= 2 } |> should.be_true
  { replies >= 1 } |> should.be_true
  receive_log(selector, "Message rate limited", 20) |> should.be_ok
  stop_capture()

  close(client)
  stop_supervisor(server_pid)
}

pub fn handler_frame_rate_counts_malformed_frames_test() -> Nil {
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

pub fn handler_closes_socket_on_oversized_text_frame_test() -> Nil {
  let #(port, server_pid) = start_frame_limited_server()
  let assert Ok(client) = connect_websocket(port, "/socket")

  let oversized_frame = string.repeat("a", 64)
  let assert Ok(_) = send_text(client, oversized_frame)
  receive_text(client, 200)
  |> should.equal(Error(Nil))

  close(client)
  stop_supervisor(server_pid)
}

pub fn outbound_budget_evicts_and_releases_for_healthy_clients_test() -> Nil {
  let channels = start_channels()
  let assert Ok(healthy_config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames: 1, max_bytes: 1024)
  let #(healthy_port, healthy_server) =
    start_server_with_config(channels, healthy_config)
  let assert Ok(healthy_client) = connect_websocket(healthy_port, "/socket")

  let assert Ok(healthy_client) =
    send_text(healthy_client, "[null,\"one\",\"phoenix\",\"heartbeat\",{}]")
  receive_text(healthy_client, 1000) |> should.be_ok
  let assert Ok(healthy_client) =
    send_text(healthy_client, "[null,\"two\",\"phoenix\",\"heartbeat\",{}]")
  receive_text(healthy_client, 1000) |> should.be_ok
  close(healthy_client)
  stop_supervisor(healthy_server)

  let channels = start_channels()
  let assert Ok(restrictive_config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames: 1, max_bytes: 1)
  let #(restricted_port, restricted_server) =
    start_server_with_config(channels, restrictive_config)
  let assert Ok(slow_client) = connect_websocket(restricted_port, "/socket")
  let assert Ok(_) =
    send_text(slow_client, "[null,\"too-large\",\"phoenix\",\"heartbeat\",{}]")
  receive_text(slow_client, 1000) |> should.equal(Error(Nil))

  let assert Ok(reconnected) = connect_websocket(restricted_port, "/socket")
  close(reconnected)
  stop_supervisor(restricted_server)
}

pub fn stalled_client_outbound_queue_is_bounded_test() -> Nil {
  let channels = start_mixed_outbound_system()
  let assert Ok(config) =
    server.default_config("/socket")
    |> server.with_outbound_limits(max_frames: 32, max_bytes: 256)
  let #(port, server_pid) = start_server_with_config(channels, config)
  let assert Ok(slow_client) = connect_websocket(port, "/socket")
  let assert Ok(healthy_client) = connect_websocket(port, "/socket")
  let assert Ok(slow_client) =
    send_text(slow_client, "[null,\"slow\",\"room:lobby\",\"phx_join\",{}]")
  let assert Ok(healthy_client) =
    send_text(
      healthy_client,
      "[null,\"healthy\",\"room:lobby\",\"phx_join\",{}]",
    )
  receive_text(slow_client, 1000) |> should.be_ok
  receive_text(healthy_client, 1000) |> should.be_ok
  wait_for_socket_counts(channels, #(2, 2), 1000)
  |> should.equal(Ok(#(2, 2)))
  websocket_upgrade_status(port, "/socket") |> should.equal(Ok(429))

  let assert Ok(connection_pid) = suspend_server_peer(slow_client)
  let monitor = process.monitor(connection_pid)

  // Observe the suspended peer before overflow: Ewe 9 force-close kills the
  // owner, so its mailbox cannot be inspected (or resumed) after overflow.
  send_mixed_broadcasts(channels, healthy_client, 1, 5)
  process.is_alive(connection_pid) |> should.be_true
  let #(frames, bytes) = outbound_queue_usage(connection_pid)
  frames |> should.equal(10)
  { frames > 0 && frames <= 32 } |> should.be_true
  { bytes > 0 && bytes <= 256 } |> should.be_true

  // Every pair also round-trips through the healthy peer, including pairs
  // sent after the slow peer's budget has overflowed.
  send_mixed_broadcasts(channels, healthy_client, 6, 45)
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  process.demonitor_process(monitor)
  stopped
  |> should.equal(
    Ok(process.ProcessDown(monitor, connection_pid, process.Killed)),
  )
  receive_text(slow_client, 1000) |> should.equal(Error(Nil))
  close(slow_client)

  // Killing bypasses on_close: the forced-close path must unregister the
  // socket and its join, and free capacity while the healthy peer stays open.
  wait_for_socket_counts(channels, #(1, 1), 1000)
  |> should.equal(Ok(#(1, 1)))
  let assert Ok(reconnected) = connect_websocket(port, "/socket")
  let assert Ok(reconnected) =
    send_text(reconnected, "[null,\"healthy\",\"phoenix\",\"heartbeat\",{}]")
  receive_text(reconnected, 1000) |> should.be_ok
  wait_for_socket_counts(channels, #(2, 1), 1000)
  |> should.equal(Ok(#(2, 1)))
  close(reconnected)
  close(healthy_client)
  wait_for_socket_counts(channels, #(0, 0), 1000)
  |> should.equal(Ok(#(0, 0)))
  stop_supervisor(server_pid)
}

fn wait_for_socket_counts(
  channels: beryl.Sockets,
  expected: #(Int, Int),
  remaining_ms: Int,
) -> Result(#(Int, Int), snapshot.SnapshotError) {
  let counts =
    snapshot.get(channels)
    |> result.map(fn(state) {
      #(
        snapshot.connected_sockets(state),
        snapshot.joined_socket_topic_pairs(state),
      )
    })
  case counts {
    Ok(actual) if actual != expected && remaining_ms > 0 -> {
      process.sleep(10)
      wait_for_socket_counts(channels, expected, remaining_ms - 10)
    }
    other -> other
  }
}

fn send_mixed_broadcasts(
  channels: beryl.Sockets,
  healthy_client: WebsocketClient,
  index: Int,
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let text_event = "text-" <> int.to_string(index)
      beryl.broadcast(channels, "room:lobby", text_event, json.object([]))
      |> should.equal(Ok(Nil))
      receive_text(healthy_client, 1000) |> should.equal(Ok(text_event))

      let binary_event = "binary-" <> int.to_string(index)
      beryl.broadcast(channels, "room:lobby", binary_event, json.object([]))
      |> should.equal(Ok(Nil))
      receive_binary(healthy_client, 1000)
      |> should.equal(Ok(bit_array.from_string(binary_event)))

      send_mixed_broadcasts(channels, healthy_client, index + 1, remaining - 1)
    }
  }
}

fn start_mixed_outbound_system() -> beryl.Sockets {
  let phoenix = wire.phoenix_codec()
  let mixed_codec =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: codec.encode_reply(phoenix),
      encode_push: fn(_topic, event, _payload) {
        case string.starts_with(event, "binary-") {
          True -> codec.BinaryFrame(bit_array.from_string(event))
          False -> codec.TextFrame(event)
        }
      },
      encode_heartbeat_reply: codec.encode_heartbeat_reply(phoenix),
    )
  let config =
    beryl.config(mixed_codec)
    |> beryl.with_max_connections(max_connections: 2)
    |> beryl.with_max_connections_per_ip(max_connections: 2)
  start_app_system_with_update(config, fn(model, event) {
    case event {
      socket.Join(_, _, reference) ->
        socket.Next(model, [socket.AcceptJoin(reference, option.None)])
      socket.Message(_, _, _, _)
      | socket.Binary(_, _)
      | socket.Closed(_, _)
      | socket.Info(_) -> socket.Next(model, [])
    }
  })
}

fn start_app_system_with_update(
  config: beryl.Config,
  update: fn(Nil, socket.Input(Nil)) -> socket.Next(Nil),
) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start(
      config,
      init: fn(_info) { #(Nil, []) },
      update: update,
    )
  channels
}

pub fn runtime_death_closes_the_connection_test() -> Nil {
  let assert Ok(channels) =
    app_test_helper.start(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          socket.Join(_, _, ref) ->
            socket.Next(model, [
              socket.AcceptJoin(
                ref,
                option.Some(json.object([#("joined", json.bool(True))])),
              ),
            ])
          socket.Message(_, _, _, _)
          | socket.Binary(_, _)
          | socket.Closed(_, _)
          | socket.Info(_) -> socket.Next(model, [])
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

fn authentication_query(
  request: request.Request(ewe.Connection),
  name: String,
) -> Result(String, Nil) {
  case request.get_query(request) {
    Ok(parameters) -> list.key_find(parameters, name)
    Error(_) -> Error(Nil)
  }
}

pub fn on_connect_seeds_metadata_visible_in_connect_info_test() -> Nil {
  // `with_on_connect` returns ordered string metadata; it lands verbatim in
  // `ConnectInfo.seed.metadata` for an app-dispatch system's `init`.
  // Duplicate keys must be preserved — the runtime must not deduplicate them.
  let seeds = process.new_subject()
  let assert Ok(channels) =
    app_test_helper.start(
      beryl.config(wire.phoenix_codec()),
      init: fn(info: socket.ConnectInfo(Nil)) {
        process.send(seeds, info.seed)
        #(Nil, [])
      },
      update: fn(model, _event) { socket.Next(model, []) },
    )

  let config =
    server.default_config("/socket")
    |> server.with_on_connect(fn(request) {
      authentication_query(request, "token")
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
