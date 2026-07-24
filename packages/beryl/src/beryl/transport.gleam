//// Transport SPI — the contract between beryl core and WebSocket transport
//// implementations such as the `beryl_mist` package.
////
//// A transport implementation:
//// 1. Admits a connection (origin/auth policy is the transport's concern),
////    acquiring a slot with `acquire_connection_slot` and binding it with
////    `bind_connection_slot`.
//// 2. Captures `connection_owner`, installs its monitor, and atomically
////    registers the socket and closer with `admit_socket`.
//// 3. Decodes inbound frames with the codec from `active_codec` and routes
////    them with `route_decoded`, `route_decoded_binary`, or `route_binary`,
////    shedding over-rate frames via `new_message_limiter` / `take_token` and
////    oversized frames via `max_inbound_frame_bytes`.
//// 4. Announces disconnects with `socket_disconnected` and releases the
////    slot with `release_connection_slot`.

import beryl
import beryl/socket
import beryl/internal
import beryl/log
import beryl/rate_limit
import beryl/telemetry
import beryl/wire/codec
import gleam/bool
import gleam/erlang/process
import gleam/option.{type Option, Some}
import gleam/result

/// Runtime handle accepted by transport implementations.
pub type Sockets =
  beryl.Sockets

/// Connection slot permit held by a transport connection.
pub type ConnectionPermit =
  beryl.ConnectionPermit

/// Connection metadata delivered to the app's `init`.
pub type ConnectSeed =
  socket.ConnectSeed

/// Wire codec used by a transport connection.
pub type Codec =
  codec.Codec

/// Decoded inbound wire message.
pub type Inbound =
  codec.Inbound

/// Wire decode failure.
pub type DecodeError =
  codec.DecodeError

/// Build connection metadata for a WebSocket upgrade.
pub fn connect_seed(
  path path: String,
  query query: List(#(String, String)),
  headers headers: List(#(String, String)),
  metadata metadata: List(#(String, String)),
) -> ConnectSeed {
  socket.ConnectSeed(
    path: path,
    query: query,
    headers: headers,
    metadata: metadata,
  )
}

/// Decode an inbound text frame with a codec.
pub fn decode_text(codec: Codec) -> fn(String) -> Result(Inbound, DecodeError) {
  codec.decode_text(codec)
}

/// Return the codec's optional binary decoder.
pub fn decode_binary(
  codec: Codec,
) -> Option(fn(BitArray) -> Result(Inbound, DecodeError)) {
  codec.decode_binary(codec)
}

/// Format a wire decode failure for transport logging.
pub fn format_decode_error(error: DecodeError) -> String {
  codec.format_decode_error(error)
}

/// Acquire a configured connection slot.
pub fn acquire_connection_slot(
  sockets: Sockets,
  ip: String,
) -> Result(ConnectionPermit, Nil) {
  beryl.acquire_connection_slot(sockets, ip)
}

/// Bind a connection slot to the current transport process.
pub fn bind_connection_slot(permit: ConnectionPermit) -> Nil {
  beryl.bind_connection_slot(permit)
}

/// Release a held connection slot.
pub fn release_connection_slot(permit: ConnectionPermit) -> Nil {
  beryl.release_connection_slot(permit)
}

/// Return the configured maximum inbound frame size.
pub fn max_inbound_frame_bytes(sockets: Sockets) -> Int {
  beryl.max_inbound_frame_bytes(sockets)
}

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
  channels: Sockets,
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

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Announce that a socket's connection has closed.
pub fn socket_disconnected(
  sockets sockets: Sockets,
  socket_id socket_id: String,
) -> Nil {
  beryl.transport_socket_disconnected(sockets, socket_id)
}

// --- Inbound routing ---

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
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

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Route a transport-decoded binary message while preserving its binary
/// frame classification for runtime telemetry and rate accounting.
///
/// This is additive to `route_decoded`, whose text semantics are retained for
/// third-party transport compatibility.
pub fn route_decoded_binary(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  message message: Inbound,
) -> Nil {
  beryl.transport_route_decoded_binary(sockets, socket_id, message)
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
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

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// The wire codec configured for these sockets. Transports decode inbound
/// frames with it in the connection process.
pub fn active_codec(sockets: Sockets) -> Codec {
  beryl.configured_codec(sockets)
}

// --- Per-connection message rate limiting ---

/// A per-connection token bucket enforcing the configured message rate at
/// the transport edge, so a flooding socket is shed before frames are
/// decoded or enqueued on the runtime.
pub opaque type RateLimiter {
  RateLimiter(bucket: rate_limit.Bucket)
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Create a fresh per-connection message limiter, `None` when no message
/// rate is configured.
pub fn new_message_limiter(sockets: Sockets) -> Option(RateLimiter) {
  beryl.message_limits(sockets)
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

// --- Connection ownership ---

/// The lifecycle relationship between a transport connection and the runtime
/// that owns it.
///
/// App-side dispatch systems own their connections through a supervised
/// runtime. A transport should monitor the owning runtime and close the
/// connection when it dies, so a runtime crash or restart never leaves a
/// zombie connection whose frames are silently dropped by a runtime that no
/// longer knows the socket.
pub type ConnectionOwner {
  /// The owning runtime is alive at this pid. Monitor it and close the
  /// connection when it goes down.
  OwnerAlive(pid: process.Pid)
  /// This is an app-side dispatch system but its runtime is not currently
  /// running (pre-start or a restart window). A new connection cannot be
  /// owned, so the transport must refuse it rather than admit a dead socket.
  OwnerUnavailable
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Register a socket and its closer against the captured connection owner.
///
/// For `OwnerAlive(pid)`, install a monitor for `pid` before calling this
/// function. Admission succeeds only if that exact runtime instance processes
/// the registration; a restart cannot redirect it to the successor runtime.
/// On `Error`, close the connection so its bound connection permit is released.
pub fn admit_socket(
  sockets sockets: Sockets,
  owner owner: ConnectionOwner,
  socket_id socket_id: String,
  send send: fn(String) -> Result(Nil, Nil),
  send_binary send_binary: fn(BitArray) -> Result(Nil, Nil),
  codec codec: Option(Codec),
  seed seed: ConnectSeed,
  close close: fn() -> Nil,
) -> Result(Nil, Nil) {
  let expected_owner = case owner {
    OwnerAlive(pid) -> Ok(Some(pid))
    OwnerUnavailable -> {
      close()
      Error(Nil)
    }
  }
  case expected_owner {
    Error(Nil) -> Error(Nil)
    Ok(expected_owner) ->
      case
        beryl.transport_admit_socket(
          sockets,
          expected_owner,
          socket_id,
          send,
          send_binary,
          codec,
          seed,
          close,
        )
      {
        True -> Ok(Nil)
        False -> {
          close()
          Error(Nil)
        }
      }
  }
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Determine how a newly accepted connection is owned. Call this in the
/// connection process right after upgrade. On `OwnerAlive(pid)`, monitor that
/// exact pid before calling `admit_socket`; on `OwnerUnavailable`, close the
/// connection immediately.
pub fn connection_owner(sockets: Sockets) -> ConnectionOwner {
  case beryl.app_runtime_pid(sockets) {
    Ok(pid) -> OwnerAlive(pid)
    Error(Nil) -> OwnerUnavailable
  }
}
