//// Transport SPI — the contract between beryl core and WebSocket transport
//// implementations such as the `beryl_mist` package.
////
//// A transport implementation:
//// 1. Admits a connection (origin/auth policy is the transport's concern),
////    acquiring a slot with `acquire_connection_slot` and binding it with
////    `bind_connection_slot`.
//// 2. Announces the socket with `socket_connected` then `register_closer`.
//// 3. Decodes inbound frames with the codec from `active_codec` (see
////    `beryl/wire/codec`) and routes them with `route_decoded` /
////    `route_binary`, shedding over-rate frames via `new_message_limiter` /
////    `take_token` and oversized frames via `max_inbound_frame_bytes`.
//// 4. Announces disconnects with `socket_disconnected` and releases the
////    slot with `release_connection_slot`.

import beryl.{type Sockets}
import beryl/internal
import beryl/log
import beryl/rate_limit
import beryl/socket.{type ConnectSeed}
import beryl/wire/codec.{type Codec, type Inbound}
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/result

// --- Socket lifecycle ---

/// Announce a newly connected socket. `send`/`send_binary` deliver outbound
/// frames on this connection. `seed` carries the upgrade request's
/// connection data (path, query, headers, and any `with_on_connect`
/// metadata), delivered to the app's `init` as `ConnectInfo.seed`. Call
/// `register_closer` immediately after this.
pub fn socket_connected(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  send send: fn(String) -> Result(Nil, Nil),
  send_binary send_binary: fn(BitArray) -> Result(Nil, Nil),
  seed seed: ConnectSeed,
) -> Nil {
  beryl.transport_socket_connected(sockets, socket_id, send, send_binary, seed)
}

/// Register a function that force-closes the socket's underlying connection
/// so the runtime can actively evict it (e.g. heartbeat timeout) instead
/// of leaving a zombie socket whose frames are silently dropped.
pub fn register_closer(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  close close: fn() -> Nil,
) -> Nil {
  beryl.transport_register_closer(sockets, socket_id, close)
}

/// Announce that a socket's connection has closed.
pub fn socket_disconnected(
  sockets sockets: Sockets,
  socket_id socket_id: String,
) -> Nil {
  beryl.transport_socket_disconnected(sockets, socket_id)
}

// --- Inbound routing ---

/// Route a transport-decoded inbound message to the runtime. Decode in
/// the connection process (see `active_codec`) so parse cost and malformed
/// input never reach the shared runtime.
pub fn route_decoded(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  message message: Inbound,
) -> Nil {
  beryl.transport_route_decoded(sockets, socket_id, message)
}

/// Route a raw binary frame, for codecs without a binary decoder (fans out
/// to the socket's joined topics as `Binary` events delivered to `update`).
pub fn route_binary(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  data data: BitArray,
) -> Nil {
  beryl.transport_route_binary(sockets, socket_id, data)
}

// --- Configuration ---

/// The wire codec configured for these sockets. Transports decode inbound
/// frames with it in the connection process.
pub fn active_codec(sockets: Sockets) -> Codec {
  beryl.configured_codec(sockets)
}

/// The configured inbound frame size cap. Transports close a connection
/// whose assembled frame exceeds this many bytes, before wire decoding.
pub fn max_inbound_frame_bytes(sockets: Sockets) -> Int {
  beryl.max_inbound_frame_bytes(sockets)
}

// --- Connection limits ---

/// A held per-IP connection slot returned by `acquire_connection_slot`.
///
/// Opaque so Beryl can restructure the connection limiter without breaking
/// transport authors. Hold it for the lifetime of the connection and pass it
/// to `release_connection_slot` when the connection closes. When no per-IP
/// limit is configured the permit is an admit-everything placeholder and
/// releasing it is a no-op.
pub type ConnectionPermit =
  beryl.ConnectionPermit

/// Try to acquire a configured per-IP connection slot.
///
/// Transports call this before admitting a connection, passing the **real
/// socket peer IP**. Do not pass a client-supplied address (e.g. from
/// `X-Forwarded-For`): a spoofed value would defeat the per-IP limit. Returns
/// `Ok(permit)` when admitted (release the permit with
/// `release_connection_slot` on close; when no limit is configured every
/// connection is admitted), or `Error(Nil)` when the peer is already at its
/// limit.
pub fn acquire_connection_slot(
  sockets sockets: Sockets,
  ip ip: String,
) -> Result(ConnectionPermit, Nil) {
  beryl.acquire_connection_slot(sockets, ip)
}

/// Bind an acquired connection slot to the calling process.
///
/// Call this from the long-lived connection process (e.g. the WebSocket
/// handler's init) after `acquire_connection_slot`. The limiter monitors the
/// caller so the slot is reclaimed even if the connection process dies
/// without running its close path — otherwise crashed connections would
/// permanently exhaust their IP's slots.
pub fn bind_connection_slot(permit permit: ConnectionPermit) -> Nil {
  beryl.bind_connection_slot(permit)
}

/// Release a per-IP connection slot acquired with `acquire_connection_slot`.
///
/// Call from the process the permit was bound to (or from an unbound
/// process when releasing before the connection was established).
pub fn release_connection_slot(permit permit: ConnectionPermit) -> Nil {
  beryl.release_connection_slot(permit)
}

// --- Per-connection message rate limiting ---

/// A per-connection token bucket enforcing the configured message rate at
/// the transport edge, so a flooding socket is shed before frames are
/// decoded or enqueued on the runtime.
pub opaque type RateLimiter {
  RateLimiter(bucket: rate_limit.Bucket)
}

/// Create a fresh per-connection message limiter, `None` when no message
/// rate is configured.
pub fn new_message_limiter(sockets: Sockets) -> Option(RateLimiter) {
  beryl.message_limits(sockets)
  |> option.map(fn(config) { RateLimiter(rate_limit.new_bucket(config)) })
}

/// Take one token; returns the updated limiter and whether the frame is
/// admitted. Transports drop the frame when `False`.
pub fn take_token(limiter: RateLimiter) -> #(RateLimiter, Bool) {
  let #(bucket, taken) = rate_limit.take(limiter.bucket)
  #(RateLimiter(bucket), result.is_ok(taken))
}

// --- Logging ---

/// A named logger for transport diagnostics, routed through beryl's
/// configured logging backend.
pub opaque type Logger {
  Logger(inner: log.Logger)
}

/// Create a named transport logger (e.g. `"beryl.transport.mist"`).
pub fn logger(name: String) -> Logger {
  Logger(internal.logger(name))
}

/// Log a warning with structured metadata.
pub fn log_warning(
  logger logger: Logger,
  message message: String,
  metadata metadata: List(#(String, String)),
) -> Nil {
  log.warn(logger.inner, message, metadata)
}

// --- Connection ownership ---

/// The pid of the runtime that owns a transport's connections, or
/// `Error(Nil)` when it is not currently running (pre-start or a restart
/// window).
///
/// Call this in the connection process right after upgrade. On `Ok(pid)`,
/// monitor `pid` and close the connection on its `Down`, so a runtime crash
/// or restart never leaves a zombie connection whose frames are silently
/// dropped by a runtime that no longer knows the socket. On `Error(Nil)` the
/// connection cannot be owned — refuse it rather than admit a dead socket.
pub fn runtime_pid(sockets: Sockets) -> Result(process.Pid, Nil) {
  beryl.app_runtime_pid(sockets)
}
