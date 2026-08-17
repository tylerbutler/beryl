//// Mist WebSocket Transport - Direct Mist integration for beryl
////
//// This module provides the bridge between Mist's native WebSocket handling
//// and the beryl runtime using Mist request and response types directly.
////
//// Transport configuration (path, `on_connect` authentication, origin
//// policy) lives in `beryl/transport/server`; build a
//// `server.TransportConfig` with its config builders and pass it to
//// [`handler`](#handler) or [`upgrade`](#upgrade). This module supplies only
//// the Mist-specific glue: the WebSocket upgrade call, frame sending, and
//// peer IP extraction.

import beryl/transport.{type Sockets}
import beryl/transport/server.{type ConnectionState, type SendRequest}
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{None, Some}
import gleam/result
import mist.{type Connection, type ResponseData, type WebsocketConnection}

/// Upgrade a request to WebSocket if it matches the configured path
///
/// Usage in your Mist handler:
/// ```gleam
/// fn handle_request(req: Request(Connection), sockets: Sockets) -> Response(ResponseData) {
///   use <- mist_transport.upgrade(req, sockets, server.default_config("/socket"))
///   // Fall through to regular HTTP routing
///   case request.path_segments(req) {
///     [] -> index_page()
///     _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
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
  next: fn() -> Response(ResponseData),
) -> Response(ResponseData) {
  let telemetry = transport.telemetry(channels, transport.Mist)
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

fn reject(status: Int) -> Response(ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn request_ip(request: Request(Connection)) -> Result(String, Nil) {
  mist.get_connection_info(request.body)
  |> result.map(fn(info) { mist.ip_address_to_string(info.ip_address) })
}

/// Build a combined request handler that serves both WebSocket upgrades and
/// regular HTTP from a single Mist listener.
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
/// mist_transport.handler(sockets, server.default_config("/socket"), http_handler)
/// |> mist.new
/// |> mist.port(8000)
/// |> mist.start
/// ```
pub fn handler(
  channels: Sockets,
  config: server.TransportConfig(Connection),
  http_fallback: fn(Request(Connection)) -> Response(ResponseData),
) -> fn(Request(Connection)) -> Response(ResponseData) {
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
) -> Response(ResponseData) {
  let seed = server.connect_seed(request, connect_metadata)
  mist.websocket_with_frame_limit(
    request: request,
    handler: on_message,
    on_init: fn(_connection) {
      let #(state, selector) =
        server.init_connection(
          sockets: channels,
          seed: seed,
          connection_permit: connection_permit,
          base_selector: process.new_selector(),
          logger_name: "beryl_mist",
          telemetry: telemetry,
          codec: None,
        )
      #(state, Some(selector))
    },
    on_close: server.close_connection,
    max_frame_bytes: transport.max_inbound_frame_bytes(channels),
  )
}

/// Handle incoming WebSocket messages.
///
/// Inbound frames run the shared size/rate/decode pipeline; outbound
/// `SendRequest`s from the runtime are written to the Mist connection.
fn on_message(
  state: ConnectionState,
  message: mist.WebsocketMessage(SendRequest),
  connection: WebsocketConnection,
) -> mist.Next(ConnectionState, SendRequest) {
  case message {
    mist.Text(text) -> resume(server.handle_text_frame(state, text))
    mist.Binary(data) -> resume(server.handle_binary_frame(state, data))
    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Custom(server.Close) -> mist.stop()
    mist.Custom(server.SendText(text)) -> {
      let _send_result = mist.send_text_frame(connection, text)
      mist.continue(state)
    }
    mist.Custom(server.SendBinary(data)) -> {
      let _send_result = mist.send_binary_frame(connection, data)
      mist.continue(state)
    }
  }
}

fn resume(
  outcome: server.FrameDisposition,
) -> mist.Next(ConnectionState, SendRequest) {
  case outcome {
    server.Continue(state) -> mist.continue(state)
    server.Stop -> mist.stop()
  }
}
