//// Transport SPI — the contract between beryl core and WebSocket transport
//// implementations such as the `beryl_mist` package.
////
//// A transport implementation:
//// 1. Admits a connection (origin/auth policy is the transport's concern),
////    acquiring a slot with `beryl.acquire_connection_slot` and binding it
////    with `beryl.bind_connection_slot`.
//// 2. Announces the socket with `socket_connected` — or
////    `socket_connected_with_codec` when the connection speaks a framing
////    other than the configured codec — then `register_closer`.
//// 3. Decodes inbound frames with the codec from `active_codec` (see
////    `beryl/wire/codec`) and routes them with `route_decoded` /
////    `route_binary`, shedding over-rate frames via `new_message_limiter` /
////    `take_token` and oversized frames via `beryl.max_inbound_frame_bytes`.
//// 4. Announces disconnects with `socket_disconnected` and releases the
////    slot with `beryl.release_connection_slot`.

import beryl.{type Channels}
import beryl/coordinator
import beryl/internal
import beryl/log
import beryl/rate_limit
import beryl/telemetry
import beryl/wire/codec.{type Codec, type Inbound}
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/option.{type Option, None}
import gleam/result

// --- Telemetry ---

/// WebSocket transport implementations in beryl's telemetry schema.
pub type TelemetryTransport {
  Mist
  Ewe
}

/// Closed terminal outcomes for a matched WebSocket upgrade.
pub type UpgradeOutcome {
  UpgradeSucceeded
  OriginRejected
  VersionRejected
  AuthRejected
  CapacityRejected
  HandshakeFailed
}

/// WebSocket data frame kinds.
pub type FrameKind {
  TextFrame
  BinaryFrame
}

/// Closed terminal outcomes for inbound frame processing.
pub type FrameOutcome {
  FrameRouted
  FrameOversized
  FrameRateLimited
  FrameDecodeFailed
}

/// Cheap transport telemetry context. When disabled, starting and stopping an
/// operation avoid VM clock calls and event construction.
pub opaque type Telemetry {
  Telemetry(enabled: Bool, transport: telemetry.Transport)
}

// nolint: unused_exports -- transport SPI
/// Create a telemetry context from the channels configuration.
pub fn telemetry(
  channels: Channels,
  transport: TelemetryTransport,
) -> Telemetry {
  Telemetry(
    enabled: beryl.channels_telemetry_enabled(channels),
    transport: case transport {
      Mist -> telemetry.Mist
      Ewe -> telemetry.Ewe
    },
  )
}

// nolint: unused_exports -- transport SPI
/// Start a timed transport operation. Returns a zero sentinel when disabled.
pub fn telemetry_start(context: Telemetry) -> Int {
  use <- bool.guard(when: !context.enabled, return: 0)
  telemetry.start_time()
}

// nolint: unused_exports -- transport SPI
/// Emit exactly one terminal matched-upgrade event.
pub fn telemetry_upgrade_stop(
  context: Telemetry,
  started_at: Int,
  outcome: UpgradeOutcome,
) -> Nil {
  use <- bool.guard(when: !context.enabled, return: Nil)
  telemetry.emit(
    True,
    telemetry.TransportUpgradeStop(
      duration: telemetry.duration_since(started_at),
      transport: context.transport,
      outcome: case outcome {
        UpgradeSucceeded -> telemetry.UpgradeSucceeded
        OriginRejected -> telemetry.OriginRejected
        VersionRejected -> telemetry.VersionRejected
        AuthRejected -> telemetry.AuthRejected
        CapacityRejected -> telemetry.CapacityRejected
        HandshakeFailed -> telemetry.HandshakeFailed
      },
    ),
  )
}

// nolint: unused_exports -- transport SPI
/// Emit exactly one terminal inbound-frame event.
pub fn telemetry_frame_stop(
  context: Telemetry,
  started_at: Int,
  bytes: Int,
  kind: FrameKind,
  outcome: FrameOutcome,
) -> Nil {
  use <- bool.guard(when: !context.enabled, return: Nil)
  telemetry.emit(
    True,
    telemetry.TransportFrameStop(
      duration: telemetry.duration_since(started_at),
      bytes: bytes,
      transport: context.transport,
      kind: case kind {
        TextFrame -> telemetry.TextFrame
        BinaryFrame -> telemetry.BinaryFrame
      },
      outcome: case outcome {
        FrameRouted -> telemetry.FrameRouted
        FrameOversized -> telemetry.FrameOversized
        FrameRateLimited -> telemetry.FrameRateLimited
        FrameDecodeFailed -> telemetry.FrameDecodeFailed
      },
    ),
  )
}

// --- Socket lifecycle ---

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Announce a newly connected socket. `send`/`send_binary` deliver outbound
/// frames on this connection; `assigns` seeds connect-time socket assigns
/// (type-erased internally) that channels see at join. Call `register_closer`
/// immediately after this.
pub fn socket_connected(
  channels channels: Channels,
  socket_id socket_id: String,
  send send: fn(String) -> Result(Nil, Nil),
  send_binary send_binary: fn(BitArray) -> Result(Nil, Nil),
  assigns assigns: assigns,
) -> Nil {
  socket_connected_with_codec(
    channels: channels,
    socket_id: socket_id,
    send: send,
    send_binary: send_binary,
    codec: None,
    assigns: assigns,
  )
}

/// Announce a newly connected socket that negotiates its own wire format.
/// `Some(codec)` frames this connection's outbound messages with `codec`
/// instead of the configured one, so a single coordinator — sharing channels,
/// pubsub and presence — can serve transports speaking different framings.
/// `None` is equivalent to `socket_connected`.
pub fn socket_connected_with_codec(
  channels channels: Channels,
  socket_id socket_id: String,
  send send: fn(String) -> Result(Nil, Nil),
  send_binary send_binary: fn(BitArray) -> Result(Nil, Nil),
  codec codec: Option(Codec),
  assigns assigns: assigns,
) -> Nil {
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      socket_id,
      send,
      send_binary,
      codec,
      erase(assigns),
    ),
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
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.RegisterCloser(socket_id, close),
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Announce that a socket's connection has closed.
pub fn socket_disconnected(
  channels channels: Channels,
  socket_id socket_id: String,
) -> Nil {
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketDisconnected(socket_id),
  )
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
  coordinator.route_decoded(
    beryl.coordinator_subject(channels),
    socket_id,
    message,
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Route a transport-decoded binary message to the coordinator.
///
/// This is additive to `route_decoded`, whose text semantics are retained for
/// third-party transport compatibility.
pub fn route_decoded_binary(
  channels channels: Channels,
  socket_id socket_id: String,
  message message: Inbound,
) -> Nil {
  coordinator.route_decoded_binary(
    beryl.coordinator_subject(channels),
    socket_id,
    message,
  )
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Route a raw binary frame, for codecs without a binary decoder (fans out
/// to the socket's joined topics' `handle_binary`).
pub fn route_binary(
  channels channels: Channels,
  socket_id socket_id: String,
  data data: BitArray,
) -> Nil {
  coordinator.route_binary(beryl.coordinator_subject(channels), socket_id, data)
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
