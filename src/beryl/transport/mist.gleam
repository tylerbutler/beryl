//// Mist WebSocket Transport - Direct Mist integration for beryl
////
//// This module provides the bridge between Mist's native WebSocket handling
//// and the beryl coordinator using Mist request and response types directly.

import beryl.{type Channels}
import beryl/coordinator.{type Message as CoordinatorMessage}
import beryl/wire/codec.{type Codec}
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

/// Configuration for the Mist WebSocket transport
///
/// The `assigns` type parameter is the socket-level state produced by the
/// `on_connect` hook. It defaults to `Nil` when no hook is configured.
pub type TransportConfig(assigns) {
  TransportConfig(
    /// URL path to match for WebSocket upgrade (e.g., "/socket")
    path: String,
    /// Optional socket-level connect/authentication callback invoked once,
    /// before the WebSocket upgrade.
    ///
    /// Runs the Phoenix `UserSocket.connect/3` analogue: it authenticates the
    /// whole connection a single time and can reject it before any channel
    /// join. Return `Ok(assigns)` to allow the connection and seed initial
    /// socket assigns (visible to channels at join), or `Error(Nil)` to reject
    /// with a 403 Forbidden response. When None, all connections are allowed
    /// and assigns start empty (`Nil`).
    on_connect: Option(fn(Request(Connection)) -> Result(assigns, Nil)),
  )
}

/// Create a default transport config with no connect hook.
///
/// The resulting config seeds `Nil` assigns. Add `with_on_connect` to
/// authenticate connections and/or seed initial assigns.
pub fn default_config(path: String) -> TransportConfig(Nil) {
  TransportConfig(path: path, on_connect: None)
}

/// Set a socket-level connect/authentication callback on the transport config.
///
/// The callback receives the HTTP request before the WebSocket upgrade and
/// runs once per socket. Return `Ok(assigns)` to allow the connection and seed
/// initial socket assigns that channels can read at join time, or `Error(Nil)`
/// to reject the connection with a 403 Forbidden response before any channel
/// join occurs.
pub fn with_on_connect(
  config: TransportConfig(a),
  callback: fn(Request(Connection)) -> Result(assigns, Nil),
) -> TransportConfig(assigns) {
  TransportConfig(path: config.path, on_connect: Some(callback))
}

/// State maintained per WebSocket connection
type ConnectionState {
  ConnectionState(
    socket_id: String,
    coordinator: Subject(CoordinatorMessage),
    codec: Codec,
  )
}

type SendRequest {
  SendText(String)
  SendBinary(BitArray)
}

/// Upgrade a request to WebSocket if it matches the configured path
///
/// Usage in your Mist handler:
/// ```gleam
/// fn handle_request(req: Request(Connection), channels: Channels) -> Response(ResponseData) {
///   use <- mist_transport.upgrade(req, channels, mist_transport.default_config("/socket"))
///   // Fall through to regular HTTP routing
///   case request.path_segments(req) {
///     [] -> index_page()
///     _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
///   }
/// }
/// ```
pub fn upgrade(
  request: Request(Connection),
  channels: Channels,
  config: TransportConfig(assigns),
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
            Ok(assigns) ->
              do_upgrade(request, channels, unsafe_coerce_to_dynamic(assigns))
            Error(Nil) ->
              response.new(403)
              |> response.set_body(mist.Bytes(bytes_tree.new()))
          }
        None -> do_upgrade(request, channels, dynamic.nil())
      }
    }
  }
}

/// Determine whether a request is a WebSocket upgrade request.
///
/// Checks for the standard `Upgrade: websocket` header (case-insensitive).
/// Use this to distinguish WebSocket handshakes from regular HTTP traffic on
/// the same listener.
@internal
pub fn is_websocket_request(request: Request(Connection)) -> Bool {
  case request.get_header(request, "upgrade") {
    Ok(value) -> string.lowercase(value) == "websocket"
    Error(Nil) -> False
  }
}

/// Build a combined request handler that serves both WebSocket channels and
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
/// mist_transport.handler(channels, mist_transport.default_config("/socket"), http_handler)
/// |> mist.new
/// |> mist.port(8000)
/// |> mist.start
/// ```
pub fn handler(
  channels: Channels,
  config: TransportConfig(assigns),
  http_fallback: fn(Request(Connection)) -> Response(ResponseData),
) -> fn(Request(Connection)) -> Response(ResponseData) {
  fn(request) {
    case is_websocket_request(request) {
      True ->
        upgrade(request, channels, config, fn() { http_fallback(request) })
      False -> http_fallback(request)
    }
  }
}

/// Alternative: upgrade any request to WebSocket (caller handles path matching)
///
/// Note: This function does not invoke the `on_connect` callback from
/// `TransportConfig`. Sockets upgraded this way start with empty (`Nil`)
/// assigns. If you need authentication or seeded assigns, either use `upgrade`
/// with a full config or call your auth check before this function.
@internal
pub fn upgrade_connection(
  request: Request(Connection),
  channels: Channels,
) -> Response(ResponseData) {
  do_upgrade(request, channels, dynamic.nil())
}

/// Perform the actual WebSocket upgrade
fn do_upgrade(
  request: Request(Connection),
  channels: Channels,
  connect_assigns: Dynamic,
) -> Response(ResponseData) {
  mist.websocket(
    request: request,
    handler: fn(state, message, connection) {
      on_message(state, message, connection)
    },
    on_init: fn(connection) {
      on_init(
        connection,
        channels.coordinator,
        channels.config.codec,
        connect_assigns,
      )
    },
    on_close: on_close,
  )
}

/// Initialize WebSocket connection
fn on_init(
  _connection: WebsocketConnection,
  coordinator: Subject(CoordinatorMessage),
  codec: Codec,
  connect_assigns: Dynamic,
) -> #(ConnectionState, Option(process.Selector(SendRequest))) {
  // Generate unique socket ID
  let socket_id = generate_socket_id()
  let send_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(send_subject)

  // Create send function that the coordinator can use
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    process.send(send_subject, SendText(text))
    Ok(Nil)
  }

  let send_binary_fn = fn(data: BitArray) -> Result(Nil, Nil) {
    process.send(send_subject, SendBinary(data))
    Ok(Nil)
  }

  // Register with coordinator, seeding any connect-time assigns
  process.send(
    coordinator,
    coordinator.SocketConnected(
      socket_id,
      send_fn,
      send_binary_fn,
      connect_assigns,
    ),
  )

  let state =
    ConnectionState(
      socket_id: socket_id,
      coordinator: coordinator,
      codec: codec,
    )

  #(state, Some(selector))
}

/// Handle incoming WebSocket messages.
///
/// Frames are decoded on the per-connection process, then routed to the
/// coordinator for dispatch. Malformed frames fall back to the coordinator so
/// diagnostics stay centralized.
fn on_message(
  state: ConnectionState,
  message: mist.WebsocketMessage(SendRequest),
  connection: WebsocketConnection,
) -> mist.Next(ConnectionState, SendRequest) {
  case message {
    mist.Text(text) -> {
      case state.codec.decode_text(text) {
        Ok(inbound) ->
          coordinator.route_decoded(state.coordinator, state.socket_id, inbound)
        // nolint: thrown_away_error -- decode failure falls back to raw coordinator routing for centralized diagnostics
        Error(_) ->
          coordinator.route_message(state.coordinator, state.socket_id, text)
      }
      mist.continue(state)
    }
    mist.Binary(data) -> {
      case state.codec.decode_binary {
        Some(decode) ->
          case decode(data) {
            Ok(inbound) ->
              coordinator.route_decoded(
                state.coordinator,
                state.socket_id,
                inbound,
              )
            // nolint: thrown_away_error -- decode failure falls back to raw coordinator routing for centralized diagnostics
            Error(_) ->
              coordinator.route_binary(state.coordinator, state.socket_id, data)
          }
        None ->
          coordinator.route_binary(state.coordinator, state.socket_id, data)
      }
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Custom(SendText(text)) -> {
      mist.send_text_frame(connection, text)
      |> result.replace(mist.continue(state))
      |> result.unwrap(mist.continue(state))
    }
    mist.Custom(SendBinary(data)) -> {
      mist.send_binary_frame(connection, data)
      |> result.replace(mist.continue(state))
      |> result.unwrap(mist.continue(state))
    }
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

/// Unsafe coercion to Dynamic - only used to type-erase connect-time assigns
/// before handing them to the coordinator.
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_to_dynamic(value: a) -> Dynamic
