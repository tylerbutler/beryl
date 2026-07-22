//// Transport SPI — the contract between beryl core and WebSocket transport
//// implementations such as the `beryl_mist` package.
////
//// A transport implementation:
//// 1. Admits a connection (origin/auth policy is the transport's concern),
////    acquiring a slot with `beryl.acquire_connection_slot` and binding it
////    with `beryl.bind_connection_slot`.
//// 2. Announces the socket with `socket_connected` then `register_closer`.
//// 3. Decodes inbound frames with the codec from `active_codec` (see
////    `beryl/wire/codec`) and routes them with `route_decoded` /
////    `route_binary`, shedding over-rate frames via `new_message_limiter` /
////    `take_token` and oversized frames via `beryl.max_inbound_frame_bytes`.
//// 4. Announces disconnects with `socket_disconnected` and releases the
////    slot with `beryl.release_connection_slot`.

import beryl.{type Channels}
import beryl/event.{type ConnectSeed}
import beryl/internal
import beryl/log
import beryl/rate_limit
import beryl/wire/codec.{type Codec, type Inbound}
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import gleam/result

// --- Socket lifecycle ---

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Announce a newly connected socket. `send`/`send_binary` deliver outbound
/// frames on this connection. `assigns` seeds connect-time socket assigns
/// (type-erased internally) for channel-module systems; `seed` carries the
/// upgrade request's connection data for app-dispatch systems (delivered to
/// the app's `init` as `ConnectInfo.seed`). Call `register_closer`
/// immediately after this.
pub fn socket_connected(
  channels channels: Channels,
  socket_id socket_id: String,
  send send: fn(String) -> Result(Nil, Nil),
  send_binary send_binary: fn(BitArray) -> Result(Nil, Nil),
  assigns assigns: assigns,
  seed seed: ConnectSeed,
) -> Nil {
  beryl.transport_socket_connected(
    channels,
    socket_id,
    send,
    send_binary,
    erase(assigns),
    seed,
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Register a function that force-closes the socket's underlying connection
/// so the coordinator can actively evict it (e.g. heartbeat timeout) instead
/// of leaving a zombie socket whose frames are silently dropped.
pub fn register_closer(
  channels channels: Channels,
  socket_id socket_id: String,
  close close: fn() -> Nil,
) -> Nil {
  beryl.transport_register_closer(channels, socket_id, close)
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Announce that a socket's connection has closed.
pub fn socket_disconnected(
  channels channels: Channels,
  socket_id socket_id: String,
) -> Nil {
  beryl.transport_socket_disconnected(channels, socket_id)
}

// --- Inbound routing ---

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Route a transport-decoded inbound message to the coordinator. Decode in
/// the connection process (see `active_codec`) so parse cost and malformed
/// input never reach the shared coordinator.
pub fn route_decoded(
  channels channels: Channels,
  socket_id socket_id: String,
  message message: Inbound,
) -> Nil {
  beryl.transport_route_decoded(channels, socket_id, message)
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Route a raw binary frame, for codecs without a binary decoder (fans out
/// to the socket's joined topics' `handle_binary`).
pub fn route_binary(
  channels channels: Channels,
  socket_id socket_id: String,
  data data: BitArray,
) -> Nil {
  beryl.transport_route_binary(channels, socket_id, data)
}

// --- Configuration ---

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// The wire codec configured for these channels. Transports decode inbound
/// frames with it in the connection process.
pub fn active_codec(channels: Channels) -> Codec {
  beryl.configured_codec(channels)
}

// --- Per-connection message rate limiting ---

/// A per-connection token bucket enforcing the configured message rate at
/// the transport edge, so a flooding socket is shed before frames are
/// decoded or enqueued on the coordinator.
pub opaque type RateLimiter {
  RateLimiter(bucket: rate_limit.Bucket)
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Create a fresh per-connection message limiter, `None` when no message
/// rate is configured.
pub fn new_message_limiter(channels: Channels) -> Option(RateLimiter) {
  beryl.message_limits(channels)
  |> option.map(fn(config) { RateLimiter(rate_limit.new_bucket(config)) })
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
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

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Create a named transport logger (e.g. `"beryl.transport.mist"`).
pub fn logger(name: String) -> Logger {
  Logger(internal.logger(name))
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Log a warning with structured metadata.
pub fn log_warning(
  logger logger: Logger,
  message message: String,
  metadata metadata: List(#(String, String)),
) -> Nil {
  log.warn(logger.inner, message, metadata)
}

/// Type-erase connect-time assigns before handing them to the coordinator.
@external(erlang, "beryl_ffi", "identity")
fn erase(value: anything) -> Dynamic
