//// WebSocket Transport - Wisp integration for beryl
////
//// This module provides the bridge between Wisp's WebSocket handling
//// and the beryl coordinator. It handles:
//// - WebSocket connection lifecycle
//// - Phoenix wire protocol parsing
//// - Routing messages to/from the coordinator

import beryl/coordinator.{type Message as CoordinatorMessage}
import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import wisp
import wisp/websocket

/// Get current process PID as Dynamic (for handler_pid in SocketConnected)
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce(value: a) -> Dynamic

fn get_self() -> Dynamic {
  unsafe_coerce(process.self())
}

/// Configuration for the WebSocket transport
pub type TransportConfig {
  TransportConfig(
    /// URL path to match for WebSocket upgrade (e.g., "/socket")
    path: String,
    /// Optional authentication callback invoked before upgrading.
    /// Return Ok(Nil) to allow the connection, Error(Nil) to reject with 403.
    /// When None, all connections are allowed (default).
    on_connect: Option(fn(wisp.Request) -> Result(Nil, Nil)),
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
  callback: fn(wisp.Request) -> Result(Nil, Nil),
) -> TransportConfig {
  TransportConfig(..config, on_connect: Some(callback))
}

/// State maintained per WebSocket connection
type ConnectionState {
  ConnectionState(socket_id: String, coordinator: Subject(CoordinatorMessage))
}

/// Upgrade a request to WebSocket if it matches the configured path
///
/// Usage in your Wisp router:
/// ```gleam
/// fn handle_request(req: Request, channels: Channels) -> Response {
///   use <- websocket.upgrade(req, channels.coordinator, websocket.default_config("/socket"))
///   // Fall through to regular HTTP routing
///   case wisp.path_segments(req) {
///     [] -> index_page()
///     _ -> wisp.not_found()
///   }
/// }
/// ```
pub fn upgrade(
  request: wisp.Request,
  coordinator: Subject(CoordinatorMessage),
  config: TransportConfig,
  next: fn() -> wisp.Response,
) -> wisp.Response {
  // Check if path matches
  let path = "/" <> string.join(wisp.path_segments(request), "/")

  case path == config.path {
    False -> next()
    True -> {
      // Run on_connect callback if configured
      case config.on_connect {
        Some(callback) ->
          case callback(request) {
            Ok(Nil) -> do_upgrade(request, coordinator)
            Error(Nil) -> wisp.response(403)
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
  request: wisp.Request,
  coordinator: Subject(CoordinatorMessage),
) -> wisp.Response {
  do_upgrade(request, coordinator)
}

/// Perform the actual WebSocket upgrade
fn do_upgrade(
  request: wisp.Request,
  coordinator: Subject(CoordinatorMessage),
) -> wisp.Response {
  wisp.websocket(
    request,
    on_init: fn(connection) { on_init(connection, coordinator) },
    on_message: on_message,
    on_close: on_close,
  )
}

/// Initialize WebSocket connection
fn on_init(
  connection: websocket.Connection,
  coordinator: Subject(CoordinatorMessage),
) -> #(ConnectionState, Option(process.Selector(a))) {
  // Generate unique socket ID
  let socket_id = generate_socket_id()

  // Create send function that the coordinator can use
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    websocket.send_text(connection, text)
    |> result.replace(Nil)
    |> result.replace_error(Nil)
  }

  let send_binary_fn = fn(data: BitArray) -> Result(Nil, Nil) {
    websocket.send_binary(connection, data)
    |> result.replace(Nil)
    |> result.replace_error(Nil)
  }

  // Register with coordinator (in wisp transport, self() is the handler)
  let handler_pid = get_self()
  process.send(
    coordinator,
    coordinator.SocketConnected(socket_id, send_fn, send_binary_fn, handler_pid),
  )

  let state = ConnectionState(socket_id: socket_id, coordinator: coordinator)

  // No custom selector needed for MVP
  #(state, None)
}

/// Handle incoming WebSocket messages
fn on_message(
  state: ConnectionState,
  message: websocket.Message(a),
  _connection: websocket.Connection,
) -> websocket.Next(ConnectionState) {
  case message {
    websocket.Text(text) -> {
      coordinator.route_message(state.coordinator, state.socket_id, text)
      websocket.Continue(state)
    }
    websocket.Binary(data) -> {
      coordinator.route_binary(state.coordinator, state.socket_id, data)
      websocket.Continue(state)
    }
    websocket.Closed | websocket.Shutdown -> websocket.Stop
    websocket.Custom(_) -> websocket.Continue(state)
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
