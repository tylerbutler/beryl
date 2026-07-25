//// Server-agnostic WebSocket transport infrastructure.
////
//// This module carries everything a WebSocket transport package needs that
//// does not depend on a particular web server: transport configuration and
//// its builders, the upgrade admission pipeline (path matching, origin
//// policy, `?vsn` negotiation, connection limits, `on_connect`
//// authentication), per-connection lifecycle choreography, and the inbound
//// frame pipeline (size caps, rate limiting, decoding, routing).
////
//// Transport packages such as `beryl_mist` and `beryl_ewe` supply only the
//// server-specific glue: the WebSocket upgrade call, frame sending, and peer
//// IP extraction. All functions here are generic over the `gleam/http`
//// request body type, so one config value works with any transport whose
//// server exposes `gleam/http` requests.

import beryl.{type Sockets}
import beryl/socket.{type ConnectSeed}
import beryl/transport.{type ConnectionPermit, type RateLimiter}
import beryl/transport/origin.{type OriginPolicy}
import beryl/wire/codec.{type Codec}
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/erlang/process.{type Selector}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// --- Transport configuration ---

/// Configuration for a WebSocket transport.
///
/// Generic over the server's request body type (`body`), so the same config
/// value works with any transport built on `gleam/http` requests.
pub opaque type TransportConfig(body) {
  TransportConfig(
    /// URL path to match for WebSocket upgrade (e.g., "/socket")
    path: String,
    /// Optional socket-level connect/authentication callback invoked once,
    /// before the WebSocket upgrade.
    ///
    /// Runs the Phoenix `UserSocket.connect/3` analogue: it authenticates the
    /// whole connection a single time and can reject it before any topic
    /// join. Return `Ok(metadata)` to allow the connection and seed
    /// `ConnectSeed.metadata` (an ordered list of string pairs, visible to
    /// the app's `init` via `ConnectInfo.seed`), or `Error(ConnectRejected)`
    /// to reject with a 403 Forbidden response. When `None`, all connections
    /// are allowed and metadata starts empty (`[]`).
    on_connect: Option(
      fn(Request(body)) -> Result(List(#(String, String)), ConnectError),
    ),
    /// Policy applied to the request `Origin` header before the WebSocket
    /// handshake. Defaults to `origin.SameOrigin`.
    origin_policy: OriginPolicy,
  )
}

/// Errors returned from a transport `on_connect` callback.
pub type ConnectError {
  /// Reject the WebSocket upgrade with `403 Forbidden`.
  ConnectRejected
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Create a default transport config with no connect hook.
///
/// The resulting config seeds empty (`[]`) `ConnectSeed.metadata` and applies
/// the `origin.SameOrigin` origin policy, which rejects cross-site WebSocket
/// upgrades before the handshake (CSWSH protection). Same-origin upgrades and
/// non-browser clients (no `Origin` header) are admitted without
/// configuration.
///
/// Add `with_on_connect` to authenticate connections and/or seed connect
/// metadata. Use `with_allowed_origins` to pin an explicit allow-list, or
/// `with_allow_all_origins` to opt out of origin checking entirely.
pub fn default_config(path: String) -> TransportConfig(body) {
  TransportConfig(
    path: path,
    on_connect: None,
    origin_policy: origin.SameOrigin,
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Set a socket-level connect/authentication callback on the transport config.
///
/// The callback receives the HTTP request before the WebSocket upgrade and
/// runs once per socket. Return `Ok(metadata)` to allow the connection and
/// seed `ConnectSeed.metadata` — an ordered list of string pairs delivered to
/// the app's `init` via `ConnectInfo.seed` — or `Error(ConnectRejected)` to
/// reject the connection with a 403 Forbidden response before any topic
/// join occurs.
///
/// Callback order and duplicate keys are preserved verbatim in
/// `ConnectSeed.metadata`; transports never log metadata values.
pub fn with_on_connect(
  config: TransportConfig(body),
  callback: fn(Request(body)) -> Result(List(#(String, String)), ConnectError),
) -> TransportConfig(body) {
  TransportConfig(
    path: config.path,
    on_connect: Some(callback),
    origin_policy: config.origin_policy,
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Restrict WebSocket upgrades to requests whose `Origin` header exactly
/// matches one of the given values.
///
/// This replaces the default `origin.SameOrigin` policy with an
/// `origin.AllowList`. Values are matched exactly against the full `Origin`
/// header, including scheme and host (and port when present), such as
/// `"https://app.example.com"`. Missing or non-matching origins are rejected
/// with `403 Forbidden` before the WebSocket handshake.
///
/// Prefer this over `with_allow_all_origins` when you know the exact origins
/// that should be allowed (e.g. behind a reverse proxy that rewrites the
/// `Host` header, where `SameOrigin` cannot see the public host).
pub fn with_allowed_origins(
  config: TransportConfig(body),
  origins: List(String),
) -> TransportConfig(body) {
  TransportConfig(
    path: config.path,
    on_connect: config.on_connect,
    origin_policy: origin.AllowList(origins),
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Disable `Origin` checking, allowing WebSocket upgrades from any origin.
///
/// This is an explicit opt-out of the default `origin.SameOrigin` CSWSH
/// protection. Only use it for sockets that do not rely on ambient browser
/// credentials (cookies, sessions) for authorization, or that authenticate
/// every message independently. For cookie/session-authenticated apps, prefer
/// the default `SameOrigin` policy or `with_allowed_origins`.
pub fn with_allow_all_origins(
  config: TransportConfig(body),
) -> TransportConfig(body) {
  TransportConfig(
    path: config.path,
    on_connect: config.on_connect,
    origin_policy: origin.AllowAll,
  )
}

// --- Upgrade admission pipeline ---

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Determine whether a request is a WebSocket upgrade request.
///
/// Checks for the standard `Upgrade: websocket` header (case-insensitive).
/// Use this to distinguish WebSocket handshakes from regular HTTP traffic on
/// the same listener.
pub fn is_websocket_request(request: Request(body)) -> Bool {
  case request.get_header(request, "upgrade") {
    Ok(value) -> string.lowercase(value) == "websocket"
    Error(Nil) -> False
  }
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Run the shared upgrade admission pipeline for a request.
///
/// When the request path matches `config.path`, the pipeline:
/// 1. Applies the configured origin policy and the `?vsn` version check,
///    rejecting failures with `reject(403)`.
/// 2. Acquires a connection slot for `request_ip(request)` (per-IP and
///    node-wide ceilings), rejecting with `reject(429)` when at a limit.
/// 3. Runs any `on_connect` callback; on `Error(ConnectRejected)` the slot is
///    released and the request is rejected with `reject(403)`.
/// 4. Hands admitted requests to `accept` with the callback's connect
///    metadata (empty when no callback is configured) and the held permit.
///
/// Non-matching paths fall through to `next`.
///
/// ## Path matching
///
/// The request path is normalised by re-joining its segments as
/// `"/" <> string.join(segments, "/")` and compared for exact equality with
/// `config.path`. Because the normalised path never has a trailing slash, a
/// config path written with a trailing slash (e.g. `"/socket/"`) will never
/// match. Configure the path without a trailing slash (e.g. `"/socket"`).
///
/// ## Connection limits
///
/// When `beryl.with_max_connections_per_ip` is configured, the limit is
/// enforced before completing the handshake, returning `reject(429)` once the
/// peer is at its limit. `request_ip` must return the **real socket peer IP**
/// from the TCP connection; forwarded headers such as `X-Forwarded-For` must
/// **not** be trusted or parsed, because clients can set them and would
/// otherwise spoof their address to bypass the limit. Behind a trusted
/// reverse proxy, all connections share the proxy's IP — resolve the real
/// client IP at the proxy layer. See the WebSocket transport guide.
///
/// When `beryl.with_max_connections` is configured, a node-wide ceiling on
/// concurrent connections across all IPs is likewise enforced with
/// `reject(429)` before allocating any long-lived socket/runtime state. The
/// two limits compose: a connection must be under both to be admitted. The
/// node-wide ceiling bounds total resource use when a per-IP limit alone
/// cannot (many distributed source addresses / IPv6 rotation). It is enforced
/// per BEAM node, so across a load-balanced cluster the effective ceiling
/// scales with the node count — use the load balancer's own controls for a
/// cluster-wide cap.
pub fn upgrade(
  request request: Request(body),
  sockets sockets: Sockets,
  config config: TransportConfig(body),
  request_ip request_ip: fn(Request(body)) -> String,
  reject reject: fn(Int) -> Response(resp),
  accept accept: fn(List(#(String, String)), ConnectionPermit) -> Response(resp),
  next next: fn() -> Response(resp),
) -> Response(resp) {
  let path = "/" <> string.join(request.path_segments(request), "/")

  case path == config.path {
    False -> next()
    True ->
      handle_matched_upgrade(
        request,
        sockets,
        config,
        request_ip,
        reject,
        accept,
      )
  }
}

fn handle_matched_upgrade(
  request: Request(body),
  sockets: Sockets,
  config: TransportConfig(body),
  request_ip: fn(Request(body)) -> String,
  reject: fn(Int) -> Response(resp),
  accept: fn(List(#(String, String)), ConnectionPermit) -> Response(resp),
) -> Response(resp) {
  use <- bool.lazy_guard(
    when: !request_origin_allowed(request, config.origin_policy),
    return: fn() { reject(403) },
  )
  use <- bool.lazy_guard(when: !request_vsn_supported(request), return: fn() {
    reject(403)
  })
  case transport.acquire_connection_slot(sockets, request_ip(request)) {
    Error(Nil) -> reject(429)
    Ok(connection_permit) ->
      run_on_connect(request, config, connection_permit, reject, accept)
  }
}

fn run_on_connect(
  request: Request(body),
  config: TransportConfig(body),
  connection_permit: ConnectionPermit,
  reject: fn(Int) -> Response(resp),
  accept: fn(List(#(String, String)), ConnectionPermit) -> Response(resp),
) -> Response(resp) {
  case config.on_connect {
    Some(callback) ->
      case callback(request) {
        Ok(metadata) -> accept(metadata, connection_permit)
        Error(ConnectRejected) -> {
          transport.release_connection_slot(connection_permit)
          reject(403)
        }
      }
    None -> accept([], connection_permit)
  }
}

/// Apply the configured origin policy to a request's `Origin` and `Host`
/// headers.
fn request_origin_allowed(
  request: Request(body),
  policy: OriginPolicy,
) -> Bool {
  origin.allowed(
    policy: policy,
    origin: request.get_header(request, "origin") |> option.from_result,
    host: request.get_header(request, "host") |> option.from_result,
  )
}

/// Check the request's `?vsn=` query parameter. A missing or unparseable
/// query string means no version was requested, which is accepted.
fn request_vsn_supported(request: Request(body)) -> Bool {
  case request.get_query(request) {
    Ok(params) ->
      origin.vsn_supported(list.key_find(params, "vsn") |> option.from_result)
    Error(Nil) -> True
  }
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Release a held connection slot when a WebSocket handshake fails.
///
/// A failed handshake (e.g. missing `Sec-WebSocket-Key`, reported as a
/// status of 400 or above) never runs the connection's init/close callbacks,
/// so the acquired slot must be released here or repeated bad handshakes
/// would permanently exhaust the IP's slots. Pipe the server's upgrade
/// response through this before returning it.
pub fn release_slot_on_failed_handshake(
  response: Response(resp),
  connection_permit: Option(ConnectionPermit),
) -> Response(resp) {
  use <- bool.guard(when: response.status < 400, return: response)
  case connection_permit {
    Some(permit) -> transport.release_connection_slot(permit)
    None -> Nil
  }
  response
}

// --- Connection lifecycle ---

/// Outbound requests the runtime sends to a connection process. Transports
/// receive these as their custom/user WebSocket message and act on them:
/// send the frame, or close the connection.
pub type SendRequest {
  SendText(String)
  SendBinary(BitArray)
  /// Runtime-initiated close (e.g. heartbeat eviction).
  Close
}

/// State maintained per WebSocket connection.
pub opaque type ConnectionState {
  ConnectionState(
    socket_id: String,
    sockets: Sockets,
    connection_permit: Option(ConnectionPermit),
    max_inbound_frame_bytes: Int,
    /// Wire codec for decoding inbound frames here in the connection
    /// process, so parse cost and malformed input never reach the shared
    /// runtime.
    codec: Codec,
    /// Per-connection message-rate limiter (`None` = unlimited).
    /// Enforced at the edge: frames over the rate are shed before decode,
    /// so a flooding socket cannot fill the runtime's mailbox.
    message_limiter: Option(RateLimiter),
    logger: transport.Logger,
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Assemble the connection seed delivered to an app-dispatch system's
/// `init` (`ConnectInfo.seed`). Systems that don't use connect metadata simply
/// ignore it.
///
/// `metadata` is the ordered list of string pairs returned by the
/// configured `on_connect` callback (empty when none is configured or it
/// returns no metadata); order and duplicate keys are preserved verbatim.
pub fn connect_seed(
  request: Request(body),
  metadata: List(#(String, String)),
) -> ConnectSeed {
  socket.ConnectSeed(
    path: request.path,
    query: request.get_query(request) |> result.unwrap([]),
    headers: request.headers,
    metadata: metadata,
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Initialize a newly upgraded WebSocket connection in its connection
/// process.
///
/// Binds any held connection slot to the calling process (so the slot is
/// reclaimed even if the process dies without a clean close), registers the
/// socket and a runtime-triggered closer with the runtime, and monitors the
/// owning runtime so a runtime crash or restart closes the connection rather
/// than leaving a zombie socket whose frames a restarted runtime would
/// silently drop. When the runtime is momentarily unavailable (a restart
/// window) the connection is closed immediately so no orphaned socket is
/// admitted.
///
/// Returns the connection state and a selector (extending `base_selector`)
/// that delivers `SendRequest` values from the runtime; the transport must
/// select on it and act on each request. Call `close_connection` when the
/// connection closes, and `logger_name` names the transport in decode
/// warnings (e.g. `"beryl_mist"`).
pub fn init_connection(
  sockets sockets: Sockets,
  seed seed: ConnectSeed,
  connection_permit connection_permit: Option(ConnectionPermit),
  base_selector base_selector: Selector(SendRequest),
  logger_name logger_name: String,
) -> #(ConnectionState, Selector(SendRequest)) {
  // Bind the per-IP slot to this WebSocket process so it is reclaimed even
  // if the process dies without running the transport's close callback.
  case connection_permit {
    Some(permit) -> transport.bind_connection_slot(permit)
    None -> Nil
  }

  let socket_id = generate_socket_id()
  let send_subject = process.new_subject()
  let selector = process.select(base_selector, send_subject)

  // Create send functions that the runtime can use.
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    process.send(send_subject, SendText(text))
    Ok(Nil)
  }

  let send_binary_fn = fn(data: BitArray) -> Result(Nil, Nil) {
    process.send(send_subject, SendBinary(data))
    Ok(Nil)
  }

  // Register with the runtime, seeding the connect seed (path/query/headers
  // plus any `with_on_connect` metadata).
  transport.socket_connected(
    sockets: sockets,
    socket_id: socket_id,
    send: send_fn,
    send_binary: send_binary_fn,
    seed: seed,
  )

  // Let the runtime actively close this connection (heartbeat eviction,
  // server-side disconnects) instead of leaving a zombie socket open.
  transport.register_closer(sockets: sockets, socket_id: socket_id, close: fn() {
    process.send(send_subject, Close)
  })

  // Tie this connection's lifetime to the runtime that accepted it. If that
  // runtime crashes or restarts, its registered closer is lost, so monitor it
  // here and close the connection on its death.
  let selector = case transport.connection_owner(sockets) {
    transport.OwnerAlive(runtime_pid) -> {
      let monitor = process.monitor(runtime_pid)
      process.select_specific_monitor(selector, monitor, fn(_down) { Close })
    }
    transport.OwnerUnavailable -> {
      process.send(send_subject, Close)
      selector
    }
  }

  let state =
    ConnectionState(
      socket_id: socket_id,
      sockets: sockets,
      connection_permit: connection_permit,
      max_inbound_frame_bytes: transport.max_inbound_frame_bytes(sockets),
      codec: transport.active_codec(sockets),
      message_limiter: transport.new_message_limiter(sockets),
      logger: transport.logger(logger_name),
    )

  #(state, selector)
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Clean up when a connection closes: release any held connection slot and
/// announce the disconnect to the runtime.
pub fn close_connection(state: ConnectionState) -> Nil {
  case state.connection_permit {
    Some(permit) -> transport.release_connection_slot(permit)
    None -> Nil
  }
  transport.socket_disconnected(state.sockets, state.socket_id)
}

// --- Inbound frame pipeline ---

/// What a transport should do with its connection after handling an inbound
/// frame.
pub type FrameOutcome {
  /// Keep the connection open with the updated state.
  Continue(ConnectionState)
  /// Close the connection (the frame exceeded the configured size cap).
  Stop
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Size-check, rate-check, and decode an inbound text frame in the
/// connection process, so parse cost stays there and only valid,
/// rate-admitted messages reach the shared runtime.
///
/// Oversized frames return `Stop` (close the connection); over-rate frames
/// are shed silently; undecodable frames are logged and dropped.
pub fn handle_text_frame(state: ConnectionState, text: String) -> FrameOutcome {
  use <- bool.guard(
    when: frame_too_large(state.max_inbound_frame_bytes, string.byte_size(text)),
    return: Stop,
  )
  let #(state, allowed) = take_message_token(state)
  use <- bool.guard(when: !allowed, return: Continue(state))
  case codec.decode_text(state.codec)(text) {
    Ok(msg) -> {
      transport.route_decoded(state.sockets, state.socket_id, msg)
      Continue(state)
    }
    Error(err) -> {
      transport.log_warning(
        state.logger,
        "Failed to decode wire protocol message",
        [
          #("socket_id", state.socket_id),
          #("error", codec.format_decode_error(err)),
        ],
      )
      Continue(state)
    }
  }
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Size-check, rate-check, and decode an inbound binary frame in the
/// connection process. Codecs without a binary decoder keep the raw
/// `transport.route_binary` fan-out, routed through the runtime.
///
/// Oversized frames return `Stop` (close the connection); over-rate frames
/// are shed silently; undecodable frames are logged and dropped.
pub fn handle_binary_frame(
  state: ConnectionState,
  data: BitArray,
) -> FrameOutcome {
  use <- bool.guard(
    when: frame_too_large(
      state.max_inbound_frame_bytes,
      bit_array.byte_size(data),
    ),
    return: Stop,
  )
  let #(state, allowed) = take_message_token(state)
  use <- bool.guard(when: !allowed, return: Continue(state))
  case codec.decode_binary(state.codec) {
    None -> {
      transport.route_binary(state.sockets, state.socket_id, data)
      Continue(state)
    }
    Some(decode_binary) ->
      case decode_binary(data) {
        Ok(msg) -> {
          transport.route_decoded(state.sockets, state.socket_id, msg)
          Continue(state)
        }
        Error(err) -> {
          transport.log_warning(
            state.logger,
            "Failed to decode binary wire protocol message",
            [
              #("socket_id", state.socket_id),
              #("error", codec.format_decode_error(err)),
            ],
          )
          Continue(state)
        }
      }
  }
}

/// Take a token from the connection's message limiter; always allowed when
/// no message rate is configured.
fn take_message_token(state: ConnectionState) -> #(ConnectionState, Bool) {
  case state.message_limiter {
    None -> #(state, True)
    Some(limiter) -> {
      let #(limiter, allowed) = transport.take_token(limiter)
      #(ConnectionState(..state, message_limiter: Some(limiter)), allowed)
    }
  }
}

fn frame_too_large(max_bytes: Int, actual_bytes: Int) -> Bool {
  max_bytes > 0 && actual_bytes > max_bytes
}

/// Generate a unique socket ID.
fn generate_socket_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode()
}
