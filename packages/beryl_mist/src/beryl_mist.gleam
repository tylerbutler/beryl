//// Mist WebSocket Transport - Direct Mist integration for beryl
////
//// This module bridges Mist's native WebSocket handling to the beryl runtime
//// using Mist request and response types directly.
////
//// The `beryl_ewe` package mirrors it: the two transports expose the same
//// config-builder and handler API, so an integrator can run beryl sockets on
//// either web server by choosing the matching transport package. Both consume
//// only beryl's public `beryl/transport` SPI.

import beryl/transport.{type Sockets}
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData, type WebsocketConnection}

/// Configuration for the Mist WebSocket transport
pub opaque type TransportConfig {
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
    /// to reject with a 403 Forbidden
    /// response. When `None`, all connections are allowed and metadata
    /// starts empty (`[]`).
    on_connect: Option(
      fn(Request(Connection)) -> Result(List(#(String, String)), ConnectError),
    ),
    /// Policy applied to the request `Origin` header before the WebSocket
    /// handshake. Defaults to [`SameOrigin`](#originpolicy).
    origin_policy: OriginPolicy,
  )
}

/// Errors returned from a transport `on_connect` callback.
pub type ConnectError {
  /// Reject the WebSocket upgrade with `403 Forbidden`.
  ConnectRejected
}

/// Policy for validating the browser `Origin` header before a WebSocket
/// upgrade completes.
///
/// The `Origin` check is the primary defence against Cross-Site WebSocket
/// Hijacking (CSWSH): a browser attaches ambient cookies/session credentials
/// to a WebSocket handshake regardless of which site initiated it, so a socket
/// that authenticates from those credentials must reject upgrades that
/// originate from other sites.
///
/// In every policy, a request with **no** `Origin` header is allowed: browsers
/// always send `Origin` on WebSocket handshakes, so an absent header signals a
/// non-browser client (native app, server-to-server, CLI) that is not subject
/// to the browser same-origin model and cannot be tricked into a cross-site
/// upgrade. The one exception is [`AllowList`](#originpolicy), which requires a
/// matching `Origin` and therefore rejects absent ones.
pub type OriginPolicy {
  /// Allow an upgrade only when the request `Origin` authority (host plus any
  /// port, with the scheme stripped) matches the request `Host` authority.
  /// This is the default and rejects cross-site upgrades before the handshake.
  ///
  /// A malformed or opaque `Origin` (e.g. `null` from a sandboxed iframe, or a
  /// value with no host) is rejected. Comparison is over the full `host:port`
  /// authority, so a non-default port must match on both sides.
  ///
  /// Behind a reverse proxy this compares against the `Host` header as the app
  /// sees it: ensure the proxy forwards the public `Host` unchanged, or use
  /// [`AllowList`](#originpolicy) with the public origins instead. Forwarded
  /// headers such as `X-Forwarded-Host` are not trusted, because clients can
  /// spoof them.
  SameOrigin
  /// Allow an upgrade only when the request `Origin` header matches one of the
  /// listed values exactly (including scheme, host, and any port), such as
  /// `"https://app.example.com"`. Requests without an `Origin` header, or with
  /// a non-matching one, are rejected.
  AllowList(List(String))
  /// Allow every upgrade regardless of `Origin`. This is an explicit opt-out
  /// of CSWSH protection: only use it for sockets that do not rely on ambient
  /// browser credentials (or that authenticate every message independently).
  AllowAll
}

/// Create a default transport config with no connect hook.
///
/// The resulting config seeds empty (`[]`) `ConnectSeed.metadata` and applies
/// the [`SameOrigin`](#originpolicy) origin policy, which rejects cross-site
/// WebSocket upgrades before the handshake (CSWSH protection). Same-origin
/// upgrades and non-browser clients (no `Origin` header) are admitted without
/// configuration.
///
/// Add `with_on_connect` to authenticate connections and/or seed connect
/// metadata. Use `with_allowed_origins` to pin an explicit allow-list, or
/// `with_allow_all_origins` to opt out of origin checking entirely.
pub fn default_config(path: String) -> TransportConfig {
  TransportConfig(path: path, on_connect: None, origin_policy: SameOrigin)
}

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
/// `ConnectSeed.metadata`; this transport never logs metadata values.
pub fn with_on_connect(
  config: TransportConfig,
  callback: fn(Request(Connection)) ->
    Result(List(#(String, String)), ConnectError),
) -> TransportConfig {
  TransportConfig(
    path: config.path,
    on_connect: Some(callback),
    origin_policy: config.origin_policy,
  )
}

/// Restrict WebSocket upgrades to requests whose `Origin` header exactly
/// matches one of the given values.
///
/// This replaces the default [`SameOrigin`](#originpolicy) policy with an
/// [`AllowList`](#originpolicy). Values are matched exactly against the full
/// `Origin` header, including scheme and host (and port when present), such as
/// `"https://app.example.com"`. Missing or non-matching origins are rejected
/// with `403 Forbidden` before the WebSocket handshake.
///
/// Prefer this over `with_allow_all_origins` when you know the exact origins
/// that should be allowed (e.g. behind a reverse proxy that rewrites the
/// `Host` header, where `SameOrigin` cannot see the public host).
pub fn with_allowed_origins(
  config: TransportConfig,
  origins: List(String),
) -> TransportConfig {
  TransportConfig(
    path: config.path,
    on_connect: config.on_connect,
    origin_policy: AllowList(origins),
  )
}

/// Disable `Origin` checking, allowing WebSocket upgrades from any origin.
///
/// This is an explicit opt-out of the default [`SameOrigin`](#originpolicy)
/// CSWSH protection. Only use it
/// for sockets that do not rely on ambient browser credentials (cookies,
/// sessions) for authorization, or that authenticate every message
/// independently. For cookie/session-authenticated apps, prefer the default
/// `SameOrigin` policy or `with_allowed_origins`.
pub fn with_allow_all_origins(config: TransportConfig) -> TransportConfig {
  TransportConfig(
    path: config.path,
    on_connect: config.on_connect,
    origin_policy: AllowAll,
  )
}

/// State maintained per WebSocket connection
type ConnectionState {
  ConnectionState(
    socket_id: String,
    channels: Sockets,
    connection_permit: Option(transport.ConnectionPermit),
    max_inbound_frame_bytes: Int,
    /// Wire codec for decoding inbound frames here in the connection
    /// process, so parse cost and malformed input never reach the shared
    /// runtime.
    codec: transport.Codec,
    telemetry: transport.Telemetry,
    /// Per-connection message-rate limiter (`None` = unlimited).
    /// Enforced at the edge: frames over the rate are shed before decode,
    /// so a flooding socket cannot fill the runtime's mailbox.
    message_limiter: Option(transport.RateLimiter),
  )
}

type SendRequest {
  SendText(String)
  SendBinary(BitArray)
  /// Runtime-initiated close (e.g. heartbeat eviction).
  Close
}

/// Upgrade a request to WebSocket if it matches the configured path
///
/// Usage in your Mist handler:
/// ```gleam
/// import beryl_mist as mist_transport
///
/// fn handle_request(req: Request(Connection), sockets: Sockets) -> Response(ResponseData) {
///   use <- mist_transport.upgrade(req, sockets, mist_transport.default_config("/socket"))
///   // Fall through to regular HTTP routing
///   case request.path_segments(req) {
///     [] -> index_page()
///     _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
///   }
/// }
/// ```
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
/// When `beryl.with_max_connections_per_ip` is configured, this transport
/// enforces the limit before completing the handshake and returns `429 Too
/// Many Requests` once the peer is at its limit. Enforcement uses the **real
/// socket peer IP** from the TCP connection; forwarded headers such as
/// `X-Forwarded-For` are **not** trusted or parsed, because clients can set
/// them and would otherwise spoof their address to bypass the limit. Behind a
/// trusted reverse proxy, all connections share the proxy's IP — resolve the
/// real client IP at the proxy layer. See the WebSocket transport guide.
///
/// When `beryl.with_max_connections` is configured, this transport also
/// enforces a node-wide ceiling on concurrent connections across all IPs,
/// likewise returning `429` and rejecting the upgrade before allocating any
/// long-lived socket/runtime state. The two limits compose: a connection
/// must be under both to be admitted. The node-wide ceiling bounds total
/// resource use when a per-IP limit alone cannot (many distributed source
/// addresses / IPv6 rotation). It is enforced per BEAM node, so across a
/// load-balanced cluster the effective ceiling scales with the node count —
/// use the load balancer's own controls for a cluster-wide cap.
pub fn upgrade(
  request: Request(Connection),
  channels: Sockets,
  config: TransportConfig,
  next: fn() -> Response(ResponseData),
) -> Response(ResponseData) {
  // Check if path matches
  let path = "/" <> string.join(request.path_segments(request), "/")

  case path == config.path {
    False -> next()
    True -> handle_matched_upgrade(request, channels, config)
  }
}

fn handle_matched_upgrade(
  request: Request(Connection),
  channels: Sockets,
  config: TransportConfig,
) -> Response(ResponseData) {
  let telemetry = transport.telemetry(channels, transport.Mist)
  let started_at = transport.telemetry_start(telemetry)
  use <- bool.lazy_guard(
    when: !origin_allowed(request, config.origin_policy),
    return: fn() {
      reject_upgrade(telemetry, started_at, transport.OriginRejected)
    },
  )
  use <- bool.lazy_guard(when: !vsn_supported(request), return: fn() {
    reject_upgrade(telemetry, started_at, transport.VersionRejected)
  })
  let ip = request_ip(request)
  case transport.acquire_connection_slot(channels, ip) {
    Error(Nil) -> {
      transport.telemetry_upgrade_stop(
        telemetry,
        started_at,
        transport.CapacityRejected,
      )
      response.new(429)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
    Ok(connection_permit) ->
      run_connect_and_upgrade(
        request,
        channels,
        config,
        connection_permit,
        telemetry,
        started_at,
      )
  }
}

fn reject_upgrade(
  telemetry: transport.Telemetry,
  started_at: Int,
  outcome: transport.UpgradeOutcome,
) -> Response(ResponseData) {
  transport.telemetry_upgrade_stop(telemetry, started_at, outcome)
  forbidden()
}

/// Check the client's requested wire protocol version (`?vsn=` query
/// parameter, sent by Phoenix clients) before upgrading.
///
/// beryl speaks the Phoenix V2 array framing, so `vsn=2.x` is accepted. A
/// missing `vsn` is accepted for non-Phoenix clients speaking the configured
/// codec. Anything else (e.g. the V1 object framing's `vsn=1.0.0`) is
/// rejected with `403 Forbidden` at the handshake — failing loudly instead
/// of accepting a connection whose every frame would be undecodable.
fn vsn_supported(request: Request(Connection)) -> Bool {
  case request.get_query(request) {
    Ok(params) ->
      case list.key_find(params, "vsn") {
        Ok(vsn) -> string.starts_with(vsn, "2.")
        Error(Nil) -> True
      }
    // No query string / unparseable query: no version was requested.
    Error(Nil) -> True
  }
}

/// Decide whether an upgrade is allowed under the configured origin policy.
///
/// A request with no `Origin` header is admitted for `SameOrigin` and
/// `AllowAll` (non-browser clients omit `Origin`), but rejected for
/// `AllowList`, which requires an explicit match.
fn origin_allowed(request: Request(Connection), policy: OriginPolicy) -> Bool {
  case policy {
    AllowAll -> True
    AllowList(origins) ->
      case request.get_header(request, "origin") {
        Ok(origin) -> list.contains(origins, origin)
        Error(Nil) -> False
      }
    SameOrigin ->
      case request.get_header(request, "origin") {
        // Non-browser clients don't send Origin; they can't be driven into a
        // cross-site upgrade, so admit them.
        Error(Nil) -> True
        Ok(origin) ->
          case request.get_header(request, "host") {
            Ok(host) -> same_origin(origin, host)
            // Without a Host header we cannot establish the request's own
            // authority, so fail closed.
            Error(Nil) -> False
          }
      }
  }
}

/// Compare an `Origin` header value against a `Host` header value under the
/// same-origin rule: strip the scheme from the origin and compare its
/// authority (host plus any port) to the host authority, case-insensitively.
///
/// A malformed or opaque origin (no `scheme://host`, e.g. `null`) never
/// matches. Comparison is over the full `host:port` authority, so a
/// non-default port must be present and equal on both sides.
@internal
pub fn same_origin(origin: String, host: String) -> Bool {
  case origin_authority(origin) {
    Ok(authority) -> authority == string.lowercase(host)
    Error(Nil) -> False
  }
}

/// Extract the lower-cased authority (`host[:port]`) from an `Origin` header
/// value, stripping the `scheme://` prefix. Returns `Error(Nil)` for values
/// without a scheme-delimited host (malformed or opaque origins such as
/// `null`).
fn origin_authority(origin: String) -> Result(String, Nil) {
  use #(_scheme, rest) <- result.try(string.split_once(origin, "://"))
  // An Origin has no path, but strip a trailing path defensively.
  let authority = case string.split_once(rest, "/") {
    Ok(#(authority, _path)) -> authority
    Error(Nil) -> rest
  }
  case authority {
    "" -> Error(Nil)
    _ -> Ok(string.lowercase(authority))
  }
}

fn forbidden() -> Response(ResponseData) {
  response.new(403)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn run_connect_and_upgrade(
  request: Request(Connection),
  channels: Sockets,
  config: TransportConfig,
  connection_permit: transport.ConnectionPermit,
  telemetry: transport.Telemetry,
  started_at: Int,
) -> Response(ResponseData) {
  // Run on_connect callback if configured
  case config.on_connect {
    Some(callback) ->
      case callback(request) {
        Ok(metadata) ->
          do_upgrade(
            request,
            channels,
            metadata,
            Some(connection_permit),
            telemetry,
            started_at,
          )
        Error(ConnectRejected) -> {
          transport.release_connection_slot(connection_permit)
          transport.telemetry_upgrade_stop(
            telemetry,
            started_at,
            transport.AuthRejected,
          )
          response.new(403)
          |> response.set_body(mist.Bytes(bytes_tree.new()))
        }
      }
    None ->
      do_upgrade(
        request,
        channels,
        [],
        Some(connection_permit),
        telemetry,
        started_at,
      )
  }
}

fn request_ip(request: Request(Connection)) -> String {
  case mist.get_connection_info(request.body) {
    Ok(info) -> mist.ip_address_to_string(info.ip_address)
    Error(Nil) -> "unknown"
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
/// import beryl_mist as mist_transport
///
/// mist_transport.handler(sockets, mist_transport.default_config("/socket"), http_handler)
/// |> mist.new
/// |> mist.port(8000)
/// |> mist.start
/// ```
pub fn handler(
  channels: Sockets,
  config: TransportConfig,
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
/// `TransportConfig`. Sockets upgraded this way start with empty (`[]`)
/// `ConnectSeed.metadata`. If you need authentication or seeded metadata,
/// either use `upgrade` with a full config or call your auth check before
/// this function.
pub fn upgrade_connection(
  request: Request(Connection),
  channels: Sockets,
) -> Response(ResponseData) {
  let telemetry = transport.telemetry(channels, transport.Mist)
  do_upgrade(
    request,
    channels,
    [],
    None,
    telemetry,
    transport.telemetry_start(telemetry),
  )
}

/// Assemble the connection seed delivered to an app-dispatch system's
/// `init` (`ConnectInfo.seed`). Systems that do not use connect metadata
/// simply ignore it.
///
/// `metadata` is the ordered list of string pairs returned by the
/// configured `on_connect` callback (empty when none is configured or it
/// returns no metadata); order and duplicate keys are preserved verbatim.
fn connect_seed(
  request: Request(Connection),
  metadata: List(#(String, String)),
) -> transport.ConnectSeed {
  transport.connect_seed(
    path: request.path,
    query: request.get_query(request) |> result.unwrap([]),
    headers: request.headers,
    metadata: metadata,
  )
}

/// Perform the actual WebSocket upgrade
fn do_upgrade(
  request: Request(Connection),
  channels: Sockets,
  connect_metadata: List(#(String, String)),
  connection_permit: Option(transport.ConnectionPermit),
  telemetry: transport.Telemetry,
  started_at: Int,
) -> Response(ResponseData) {
  let max_inbound_frame_bytes = transport.max_inbound_frame_bytes(channels)
  let active_codec = transport.active_codec(channels)
  let seed = connect_seed(request, connect_metadata)
  let response =
    mist.websocket(
      request: request,
      handler: fn(state, message, connection) {
        on_message(state, message, connection)
      },
      on_init: fn(connection) {
        on_init(
          connection,
          channels,
          seed,
          connection_permit,
          max_inbound_frame_bytes,
          active_codec,
          telemetry,
        )
      },
      on_close: on_close,
    )
  // A failed handshake (e.g. missing Sec-WebSocket-Key) never runs
  // on_init/on_close, so the acquired per-IP slot must be released here or
  // repeated bad handshakes would permanently exhaust the IP's slots.
  case response.status >= 400 {
    True -> {
      case connection_permit {
        Some(permit) -> transport.release_connection_slot(permit)
        None -> Nil
      }
      transport.telemetry_upgrade_stop(
        telemetry,
        started_at,
        transport.HandshakeFailed,
      )
      response
    }
    False -> {
      transport.telemetry_upgrade_stop(
        telemetry,
        started_at,
        transport.UpgradeSucceeded,
      )
      response
    }
  }
}

/// Initialize WebSocket connection
fn on_init(
  _connection: WebsocketConnection,
  channels: Sockets,
  seed: transport.ConnectSeed,
  connection_permit: Option(transport.ConnectionPermit),
  max_inbound_frame_bytes: Int,
  active_codec: transport.Codec,
  telemetry: transport.Telemetry,
) -> #(ConnectionState, Option(process.Selector(SendRequest))) {
  // Bind the per-IP slot to this WebSocket process so it is reclaimed even
  // if the process dies without running on_close.
  case connection_permit {
    Some(permit) -> transport.bind_connection_slot(permit)
    None -> Nil
  }

  // Generate unique socket ID
  let socket_id = generate_socket_id()
  let send_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(send_subject)

  // Create send function that the runtime can use
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    process.send(send_subject, SendText(text))
    Ok(Nil)
  }

  let send_binary_fn = fn(data: BitArray) -> Result(Nil, Nil) {
    process.send(send_subject, SendBinary(data))
    Ok(Nil)
  }

  let owner = transport.connection_owner(channels)
  let selector = case owner {
    transport.OwnerAlive(runtime_pid) -> {
      let monitor = process.monitor(runtime_pid)
      let selector =
        process.select_specific_monitor(selector, monitor, fn(_down) { Close })
      case
        transport.admit_socket(
          sockets: channels,
          owner: owner,
          socket_id: socket_id,
          send: send_fn,
          send_binary: send_binary_fn,
          codec: None,
          seed: seed,
          close: fn() { process.send(send_subject, Close) },
        )
      {
        Ok(Nil) -> selector
        Error(Nil) -> selector
      }
    }
    transport.OwnerUnavailable -> {
      process.send(send_subject, Close)
      selector
    }
  }

  let state =
    ConnectionState(
      socket_id: socket_id,
      channels: channels,
      connection_permit: connection_permit,
      max_inbound_frame_bytes: max_inbound_frame_bytes,
      codec: active_codec,
      telemetry: telemetry,
      message_limiter: transport.new_message_limiter(channels),
    )

  #(state, Some(selector))
}

/// Handle incoming WebSocket messages.
///
/// Frames are routed to the runtime for dispatch.
fn on_message(
  state: ConnectionState,
  message: mist.WebsocketMessage(SendRequest),
  connection: WebsocketConnection,
) -> mist.Next(ConnectionState, SendRequest) {
  case message {
    mist.Text(text) -> {
      let bytes = string.byte_size(text)
      let started_at = transport.telemetry_start(state.telemetry)
      case frame_too_large(state.max_inbound_frame_bytes, bytes) {
        True -> {
          transport.telemetry_frame_stop(
            state.telemetry,
            started_at,
            bytes,
            transport.TextFrame,
            transport.FrameOversized,
          )
          mist.stop()
        }
        False -> handle_inbound_text(state, text, bytes, started_at)
      }
    }
    mist.Binary(data) -> {
      let bytes = bit_array.byte_size(data)
      let started_at = transport.telemetry_start(state.telemetry)
      case frame_too_large(state.max_inbound_frame_bytes, bytes) {
        True -> {
          transport.telemetry_frame_stop(
            state.telemetry,
            started_at,
            bytes,
            transport.BinaryFrame,
            transport.FrameOversized,
          )
          mist.stop()
        }
        False -> handle_inbound_binary(state, data, bytes, started_at)
      }
    }

    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Custom(Close) -> mist.stop()
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

/// Rate-check and decode a text frame in the connection process, so parse
/// cost stays here and only valid, rate-admitted messages reach the shared
/// runtime.
fn handle_inbound_text(
  state: ConnectionState,
  text: String,
  bytes: Int,
  started_at: Int,
) -> mist.Next(ConnectionState, SendRequest) {
  let #(state, allowed) = take_message_token(state)
  use <- bool.lazy_guard(when: !allowed, return: fn() {
    transport.telemetry_frame_stop(
      state.telemetry,
      started_at,
      bytes,
      transport.TextFrame,
      transport.FrameRateLimited,
    )
    mist.continue(state)
  })
  case transport.decode_text(state.codec)(text) {
    Ok(msg) -> {
      transport.route_decoded(state.channels, state.socket_id, msg)
      transport.telemetry_frame_stop(
        state.telemetry,
        started_at,
        bytes,
        transport.TextFrame,
        transport.FrameRouted,
      )
      mist.continue(state)
    }
    Error(err) -> {
      transport.log_warning(
        transport_logger(),
        "Failed to decode wire protocol message",
        [
          #("socket_id", state.socket_id),
          #("error", transport.format_decode_error(err)),
        ],
      )
      transport.telemetry_frame_stop(
        state.telemetry,
        started_at,
        bytes,
        transport.TextFrame,
        transport.FrameDecodeFailed,
      )
      mist.continue(state)
    }
  }
}

/// Rate-check and decode a binary frame in the connection process. Codecs
/// without a binary decoder keep the raw `transport.route_binary` fan-out,
/// routed
/// through the runtime.
fn handle_inbound_binary(
  state: ConnectionState,
  data: BitArray,
  bytes: Int,
  started_at: Int,
) -> mist.Next(ConnectionState, SendRequest) {
  let #(state, allowed) = take_message_token(state)
  use <- bool.lazy_guard(when: !allowed, return: fn() {
    transport.telemetry_frame_stop(
      state.telemetry,
      started_at,
      bytes,
      transport.BinaryFrame,
      transport.FrameRateLimited,
    )
    mist.continue(state)
  })
  case transport.decode_binary(state.codec) {
    None -> {
      transport.route_binary(state.channels, state.socket_id, data)
      transport.telemetry_frame_stop(
        state.telemetry,
        started_at,
        bytes,
        transport.BinaryFrame,
        transport.FrameRouted,
      )
      mist.continue(state)
    }
    Some(decode_binary) ->
      case decode_binary(data) {
        Ok(msg) -> {
          transport.route_decoded_binary(state.channels, state.socket_id, msg)
          transport.telemetry_frame_stop(
            state.telemetry,
            started_at,
            bytes,
            transport.BinaryFrame,
            transport.FrameRouted,
          )
          mist.continue(state)
        }
        Error(err) -> {
          transport.log_warning(
            transport_logger(),
            "Failed to decode binary wire protocol message",
            [
              #("socket_id", state.socket_id),
              #("error", transport.format_decode_error(err)),
            ],
          )
          transport.telemetry_frame_stop(
            state.telemetry,
            started_at,
            bytes,
            transport.BinaryFrame,
            transport.FrameDecodeFailed,
          )
          mist.continue(state)
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

fn transport_logger() -> transport.Logger {
  transport.logger("beryl_mist")
}

fn frame_too_large(max_bytes: Int, actual_bytes: Int) -> Bool {
  max_bytes > 0 && actual_bytes > max_bytes
}

/// Cleanup when connection closes
fn on_close(state: ConnectionState) -> Nil {
  case state.connection_permit {
    Some(permit) -> transport.release_connection_slot(permit)
    None -> Nil
  }
  transport.socket_disconnected(state.channels, state.socket_id)
}

/// Generate a unique socket ID
fn generate_socket_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode()
}
