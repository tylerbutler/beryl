//// Mist WebSocket Transport - Direct Mist integration for beryl
////
//// This module provides the bridge between Mist's native WebSocket handling
//// and the beryl coordinator. It mirrors the Wisp transport API but uses
//// Mist types directly, giving users a lower-level alternative without
//// Wisp's abstraction layer.

import beryl/coordinator.{type Message as CoordinatorMessage}
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData, type WebsocketConnection}

/// Get current process PID as Dynamic (for handler_pid in SocketConnected)
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce(value: a) -> Dynamic

fn get_self() -> Dynamic {
  unsafe_coerce(process.self())
}

/// Configuration for the Mist WebSocket transport
pub type TransportConfig {
  TransportConfig(
    /// URL path to match for WebSocket upgrade (e.g., "/socket")
    path: String,
    /// Optional authentication callback invoked before upgrading.
    /// Return Ok(Nil) to allow the connection, Error(Nil) to reject with 403.
    /// When None, all connections are allowed (default).
    on_connect: Option(fn(Request(Connection)) -> Result(Nil, Nil)),
  )
}

/// Create a default transport config
pub fn default_config(path: String) -> TransportConfig {
  TransportConfig(path: path, on_connect: None)
}

/// Set an authentication callback on the transport config
///
/// The callback receives the HTTP request before the WebSocket upgrade.
/// Return `Ok(Nil)` to allow the connection or `Error(Nil)` to reject it
/// with a 403 Forbidden response.
pub fn with_on_connect(
  config: TransportConfig,
  callback: fn(Request(Connection)) -> Result(Nil, Nil),
) -> TransportConfig {
  TransportConfig(..config, on_connect: Some(callback))
}

/// State maintained per WebSocket connection
type ConnectionState {
  ConnectionState(socket_id: String, coordinator: Subject(CoordinatorMessage))
}

/// Upgrade a request to WebSocket if it matches the configured path
///
/// Usage in your Mist handler:
/// ```gleam
/// fn handle_request(req: Request(Connection), channels: Channels) -> Response(ResponseData) {
///   use <- mist_transport.upgrade(req, channels.coordinator, mist_transport.default_config("/socket"))
///   // Fall through to regular HTTP routing
///   case request.path_segments(req) {
///     [] -> index_page()
///     _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
///   }
/// }
/// ```
pub fn upgrade(
  request: Request(Connection),
  coordinator: Subject(CoordinatorMessage),
  config: TransportConfig,
  next: fn() -> Response(ResponseData),
) -> Response(ResponseData) {
  // Check if path matches
  let path = "/" <> string.join(request.path_segments(request), "/")

  case path == config.path {
    False -> next()
    True -> {
      // Run on_connect callback if configured
      case config.on_connect {
        Some(callback) ->
          case callback(request) {
            Ok(Nil) -> do_upgrade(request, coordinator)
            Error(Nil) ->
              response.new(403)
              |> response.set_body(mist.Bytes(bytes_tree.new()))
          }
        None -> do_upgrade(request, coordinator)
      }
    }
  }
}

/// Alternative: upgrade any request to WebSocket (caller handles path matching)
///
/// Note: This function does not invoke the `on_connect` callback from
/// `TransportConfig`. If you need authentication, either use `upgrade`
/// with a full config or call your auth check before this function.
pub fn upgrade_connection(
  request: Request(Connection),
  coordinator: Subject(CoordinatorMessage),
) -> Response(ResponseData) {
  do_upgrade(request, coordinator)
}

/// Perform the actual WebSocket upgrade
fn do_upgrade(
  request: Request(Connection),
  coordinator: Subject(CoordinatorMessage),
) -> Response(ResponseData) {
  mist.websocket(
    request: request,
    handler: fn(state, message, connection) {
      on_message(state, message, connection)
    },
    on_init: fn(connection) { on_init(connection, coordinator) },
    on_close: on_close,
  )
}

/// Initialize WebSocket connection
fn on_init(
  connection: WebsocketConnection,
  coordinator: Subject(CoordinatorMessage),
) -> #(ConnectionState, Option(process.Selector(a))) {
  // Generate unique socket ID
  let socket_id = generate_socket_id()

  // Create send function that the coordinator can use
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    mist.send_text_frame(connection, text)
    |> result.replace(Nil)
    |> result.replace_error(Nil)
  }

  let send_binary_fn = fn(data: BitArray) -> Result(Nil, Nil) {
    mist.send_binary_frame(connection, data)
    |> result.replace(Nil)
    |> result.replace_error(Nil)
  }

  // Register with coordinator
  let handler_pid = get_self()
  process.send(
    coordinator,
    coordinator.SocketConnected(socket_id, send_fn, send_binary_fn, handler_pid),
  )

  let state = ConnectionState(socket_id: socket_id, coordinator: coordinator)

  // No custom selector needed
  #(state, None)
}

/// Handle incoming WebSocket messages
fn on_message(
  state: ConnectionState,
  message: mist.WebsocketMessage(a),
  _connection: WebsocketConnection,
) -> mist.Next(ConnectionState, a) {
  case message {
    mist.Text(text) -> {
      coordinator.route_message(state.coordinator, state.socket_id, text)
      mist.continue(state)
    }
    mist.Binary(data) -> {
      coordinator.route_binary(state.coordinator, state.socket_id, data)
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Custom(_) -> mist.continue(state)
  }
}

/// Cleanup when connection closes
fn on_close(state: ConnectionState) -> Nil {
  process.send(
    state.coordinator,
    coordinator.SocketDisconnected(state.socket_id),
  )
}

/// Generate a unique socket ID
fn generate_socket_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode()
}
