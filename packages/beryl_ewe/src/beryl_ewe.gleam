//// Ewe WebSocket Transport - Direct Ewe integration for beryl
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
import ewe.{type Connection, type ResponseBody, type WebsocketConnection}
import gleam/erlang/process.{type Selector}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{None}

/// Upgrade a request to WebSocket if it matches the configured path
///
/// Usage in your Ewe handler:
/// ```gleam
/// fn handle_request(req: Request(Connection), sockets: Sockets) -> Response(ResponseBody) {
///   use <- ewe_transport.upgrade(req, sockets, server.default_config("/socket"))
///   // Fall through to regular HTTP routing
///   case request.path_segments(req) {
///     [] -> index_page()
///     _ -> response.new(404) |> response.set_body(ewe.Empty)
///   }
/// }
/// ```
///
/// Path matching, origin policy, `?vsn` version negotiation, connection
/// limits (per-IP and node-wide, rejected with `429 Too Many Requests`), and
/// the `on_connect` callback are handled by the shared admission pipeline —
/// see `beryl/transport/server.upgrade` for the full contract. Enforcement
/// uses the real socket peer IP from the TCP connection; forwarded headers
/// such as `X-Forwarded-For` are not trusted.
pub fn upgrade(
  request: Request(Connection),
  channels: Sockets,
  config: server.TransportConfig(Connection),
  next: fn() -> Response(ResponseBody),
) -> Response(ResponseBody) {
  let telemetry = transport.telemetry(channels, transport.Ewe)
  server.upgrade(
    request: request,
    sockets: channels,
    config: config,
    telemetry: telemetry,
    request_ip: request_ip,
    reject: reject,
    accept: fn(metadata, connection_permit) {
      do_upgrade(request, channels, metadata, connection_permit, telemetry)
    },
    next: next,
  )
}

fn reject(status: Int) -> Response(ResponseBody) {
  response.new(status)
  |> response.set_body(ewe.Empty)
}

fn request_ip(request: Request(Connection)) -> String {
  case ewe.get_client_info(request.body) {
    Ok(info) -> ewe.ip_address_to_string(info.ip)
    Error(Nil) -> "unknown"
  }
}

/// Build a combined request handler that serves both WebSocket upgrades and
/// regular HTTP from a single Ewe listener.
///
/// The returned function inspects each request and routes it:
/// - WebSocket upgrade requests matching the configured socket path are handed
///   to [`upgrade`](#upgrade) (which also runs any `on_connect` callback).
/// - Everything else — non-upgrade requests, or upgrades to a different path —
///   falls through to `http_fallback`.
///
/// This removes the boilerplate upgrade guard integrators would otherwise write
/// by hand:
///
/// ```gleam
/// ewe_transport.handler(sockets, server.default_config("/socket"), http_handler)
/// |> ewe.new
/// |> ewe.listening(port: 8000)
/// |> ewe.start
/// ```
pub fn handler(
  channels: Sockets,
  config: server.TransportConfig(Connection),
  http_fallback: fn(Request(Connection)) -> Response(ResponseBody),
) -> fn(Request(Connection)) -> Response(ResponseBody) {
  server.handler(
    upgrade: fn(request, next) { upgrade(request, channels, config, next) },
    http_fallback: http_fallback,
  )
}

/// Perform the actual WebSocket upgrade
fn do_upgrade(
  request: Request(Connection),
  channels: Sockets,
  connect_metadata: List(#(String, String)),
  connection_permit: transport.ConnectionPermit,
  telemetry: transport.Telemetry,
) -> Response(ResponseBody) {
  let seed = server.connect_seed(request, connect_metadata)
  ewe.upgrade_websocket(
    request,
    on_init: fn(_connection, base_selector: Selector(SendRequest)) {
      // Extend the selector Ewe provides so the runtime can push outbound
      // frames to this connection's process as `ewe.User(SendRequest)`
      // messages.
      server.init_connection(
        sockets: channels,
        seed: seed,
        connection_permit: connection_permit,
        base_selector: base_selector,
        logger_name: "beryl_ewe",
        telemetry: telemetry,
        codec: None,
      )
    },
    handler: on_message,
    on_close: fn(_connection, state) { server.close_connection(state) },
  )
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
) -> ewe.WebsocketNext(ConnectionState, SendRequest) {
  case message {
    ewe.Text(text) -> resume(server.handle_text_frame(state, text))
    ewe.Binary(data) -> resume(server.handle_binary_frame(state, data))
    ewe.User(server.Close) -> ewe.websocket_stop()
    ewe.User(server.SendText(text)) -> {
      let _ = ewe.send_text_frame(connection, text)
      ewe.websocket_continue(state)
    }
    ewe.User(server.SendBinary(data)) -> {
      let _ = ewe.send_binary_frame(connection, data)
      ewe.websocket_continue(state)
    }
  }
}

fn resume(
  outcome: server.FrameOutcome,
) -> ewe.WebsocketNext(ConnectionState, SendRequest) {
  case outcome {
    server.Continue(state) -> ewe.websocket_continue(state)
    server.Stop -> ewe.websocket_stop()
  }
}
