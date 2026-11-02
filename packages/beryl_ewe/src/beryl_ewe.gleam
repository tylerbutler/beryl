//// Ewe WebSocket transport for beryl
////
//// This module provides the bridge between Ewe's native WebSocket handling
//// and the beryl runtime using Ewe request and response types directly.
////
//// It mirrors the `beryl_mist` package: the two transports expose the same
//// handler API, so an integrator can run beryl sockets on either web server
//// by choosing the matching transport package.
////
//// Transport configuration (path, `on_connect` authentication, origin
//// policy) lives in `beryl/transport/server`; build a
//// `server.TransportConfig` with its config builders and pass it to
//// [`handler`](#handler) or [`upgrade`](#upgrade). This module supplies only
//// the Ewe-specific glue: the WebSocket upgrade call, frame sending, and
//// peer IP extraction.

import beryl/transport.{type Sockets}
import beryl/transport/server.{type ConnectionState, type SendRequest}
import ewe.{type Body, type Connection, type WebsocketConnection}
import gleam/erlang/process.{type Selector}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{None, Some}
import gleam/result

/// Upgrade a request to WebSocket if it matches the configured path.
///
/// Usage in your Ewe handler:
/// ```gleam
/// fn handle_request(http_request: Request(Connection), sockets: Sockets) -> Response(Body) {
///   use <- ewe_transport.upgrade(http_request, sockets, server.default_config("/socket"))
///   // Fall through to regular HTTP routing
///   case request.path_segments(http_request) {
///     [] -> index_page()
///     _ -> response.new(404) |> response.set_body(ewe.Empty)
///   }
/// }
/// ```
///
/// Path matching, origin policy, `?vsn` version negotiation, connection
/// limits (per-IP and per beryl system on the current node, rejected with
/// `429 Too Many Requests`), and the `on_connect` callback use the shared
/// admission pipeline. See
/// `beryl/transport/server.upgrade` for the full contract. Enforcement
/// uses the real socket peer IP from the TCP connection; forwarded headers
/// such as `X-Forwarded-For` are not trusted.
///
/// HTTP/2 extended CONNECT uses Ewe's parsed `:authority` for origin checks
/// when there is no `Host` header.
pub fn upgrade(
  request: Request(Connection),
  channels: Sockets,
  config: server.TransportConfig(Connection),
  next: fn() -> Response(Body),
) -> Response(Body) {
  let request = case
    request.method == http.Connect
    && result.is_error(request.get_header(request, "host"))
  {
    True -> {
      // Ewe validates :authority and preserves brackets around IPv6 hosts.
      let authority = case request.port {
        Some(port) -> request.host <> ":" <> int.to_string(port)
        None -> request.host
      }
      request.set_header(request, "host", authority)
    }
    False -> request
  }
  let telemetry = transport.telemetry(channels, transport.Ewe)
  server.upgrade(
    request: request,
    sockets: channels,
    config: config,
    telemetry: telemetry,
    request_ip: request_ip,
    reject: reject,
    accept: fn(metadata, connection_permit) {
      do_upgrade(
        request,
        channels,
        config,
        metadata,
        connection_permit,
        telemetry,
      )
    },
    next: next,
  )
}

fn reject(status: Int) -> Response(Body) {
  response.new(status)
  |> response.set_body(ewe.Empty)
}

fn request_ip(request: Request(Connection)) -> Result(String, Nil) {
  case ewe.get_client_info(request.body) {
    ewe.TcpSocketAddress(ip_address, _) ->
      Ok(ewe.ip_address_to_string(ip_address))
    ewe.UnixSocketAddress(_) -> Error(Nil)
  }
}

/// Build a combined request handler that serves both WebSocket upgrades and
/// regular HTTP from a single Ewe listener.
///
/// The returned function inspects and routes each request:
/// - It passes WebSocket upgrade and CONNECT requests for the socket path to
///   [`upgrade`](#upgrade), which also runs any `on_connect` callback.
///   Ewe validates the HTTP/1 handshake or HTTP/2 extended CONNECT protocol.
/// - It passes all other requests to `http_fallback`. This includes non-upgrade
///   requests and upgrades for a different path.
///
/// This removes the need to write an upgrade guard:
///
/// ```gleam
/// ewe_transport.handler(sockets, server.default_config("/socket"), http_handler)
/// |> ewe.new
/// |> ewe.listening(on: 8000)
/// |> ewe.start
/// ```
pub fn handler(
  channels: Sockets,
  config: server.TransportConfig(Connection),
  http_fallback: fn(Request(Connection)) -> Response(Body),
) -> fn(Request(Connection)) -> Response(Body) {
  fn(request: Request(Connection)) {
    case
      request.method == http.Connect || server.is_websocket_request(request)
    {
      True ->
        upgrade(request, channels, config, fn() { http_fallback(request) })
      False -> http_fallback(request)
    }
  }
}

/// Perform the actual WebSocket upgrade
fn do_upgrade(
  request: Request(Connection),
  channels: Sockets,
  config: server.TransportConfig(Connection),
  connect_metadata: List(#(String, String)),
  connection_permit: transport.ConnectionPermit,
  telemetry: transport.Telemetry,
) -> Response(Body) {
  let seed = server.connect_seed(request, connect_metadata)
  ewe.websocket(
    request,
    on_init: fn(_connection, base_selector: Selector(SendRequest)) {
      // Extend the selector Ewe provides so the runtime can push outbound
      // frames to this connection's process as `ewe.UserMessage(SendRequest)`
      // messages.
      let owner = process.self()
      server.init_connection(
        sockets: channels,
        seed: seed,
        connection_permit: connection_permit,
        base_selector: base_selector,
        config: config,
        force_close: fn() { force_close(owner) },
        logger_name: "beryl_ewe",
        telemetry: telemetry,
        codec: None,
      )
    },
    handler: on_message,
    on_close: server.close_connection,
  )
}

fn force_close(owner: process.Pid) -> Result(Nil, server.ForceCloseError) {
  process.kill(owner)
  Ok(Nil)
}

/// Handle incoming WebSocket messages.
///
/// Inbound frames run the shared size/rate/decode pipeline; outbound
/// `SendRequest`s from the runtime are written to the Ewe connection. Ewe
/// does not deliver a close message to the handler; cleanup happens in
/// `on_close`.
fn on_message(
  connection: WebsocketConnection,
  state: ConnectionState,
  message: ewe.WebsocketMessage(SendRequest),
) -> ewe.Next(ConnectionState, SendRequest) {
  case message {
    ewe.TextFrame(text) -> resume(server.handle_text_frame(state, text))
    ewe.BinaryFrame(data) -> resume(server.handle_binary_frame(state, data))
    ewe.UserMessage(server.Close) -> ewe.stop()
    ewe.UserMessage(server.SendText(text, bytes)) ->
      resume(server.finish_outbound_write(
        state,
        bytes,
        ewe.send_text_frame(connection, text) |> result.is_ok,
      ))
    ewe.UserMessage(server.SendBinary(data, bytes)) ->
      resume(server.finish_outbound_write(
        state,
        bytes,
        ewe.send_binary_frame(connection, data) |> result.is_ok,
      ))
  }
}

fn resume(
  outcome: server.FrameDisposition,
) -> ewe.Next(ConnectionState, SendRequest) {
  case outcome {
    server.Continue(state) -> ewe.continue(state)
    server.Stop -> ewe.stop()
  }
}
