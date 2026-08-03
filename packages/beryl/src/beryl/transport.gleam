//// Transport SPI — the contract between beryl core and WebSocket transport
//// implementations such as the `beryl_mist` package.
////
//// `beryl/transport/server` owns the shared admission, connection, rate,
//// decode, and telemetry pipeline. This low-level SPI keeps only the hooks a
//// transport implementation needs: exact-owner atomic admission, disconnect,
//// text/binary routing, the configured codec, and transport telemetry.

import beryl
import beryl/socket
import beryl/telemetry
import beryl/wire/codec
import gleam/bool
import gleam/erlang/process
import gleam/option.{type Option}

/// Runtime handle accepted by transport implementations.
pub type Sockets =
  beryl.Sockets

/// Connection slot permit held by a transport connection.
pub type ConnectionPermit =
  beryl.ConnectionPermit

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

/// Start a timed transport operation. Returns a zero sentinel when disabled.
pub fn telemetry_start(context: Telemetry) -> Int {
  use <- bool.guard(when: !context.enabled, return: 0)
  telemetry.start_time()
}

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

/// Announce that a socket's connection has closed.
pub fn socket_disconnected(
  sockets sockets: Sockets,
  socket_id socket_id: String,
) -> Nil {
  beryl.app_dispatch(sockets).socket_disconnected(socket_id)
}

// --- Inbound routing ---

/// Route a transport-decoded inbound message to the runtime. Decode in
/// the connection process (see `active_codec`) so parse cost and malformed
/// input never reach the shared runtime.
pub fn route_decoded(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  message message: codec.Inbound,
) -> Nil {
  beryl.app_dispatch(sockets).route_decoded(socket_id, message)
}

/// Route a transport-decoded binary message while preserving its binary
/// frame classification for runtime telemetry and rate accounting.
///
/// This is additive to `route_decoded`, whose text semantics are retained for
/// third-party transport compatibility.
pub fn route_decoded_binary(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  message message: codec.Inbound,
) -> Nil {
  beryl.app_dispatch(sockets).route_decoded_binary(socket_id, message)
}

/// Route a raw binary frame, for codecs without a binary decoder (fans out
/// to the socket's joined topics as `Binary` events delivered to `update`).
pub fn route_binary(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  data data: BitArray,
) -> Nil {
  beryl.app_dispatch(sockets).route_binary(socket_id, data)
}

// --- Configuration ---

/// The wire codec configured for these sockets. Transports decode inbound
/// frames with it in the connection process.
pub fn active_codec(sockets: Sockets) -> codec.Codec {
  beryl.configured_codec(sockets)
}

// --- Connection ownership ---

/// Return the pid of the runtime that owns transport connections.
///
/// On `Ok(pid)`, monitor that exact pid before admission and close the
/// connection on its `Down`. `Error(Nil)` means the runtime is unavailable
/// (pre-start or a restart window), so the connection must be refused.
pub fn runtime_pid(sockets: Sockets) -> Result(process.Pid, Nil) {
  beryl.app_runtime_pid(sockets)
}

/// Register a socket and its closer against the captured connection owner.
///
/// Install a monitor for `owner` before calling this function. Admission
/// succeeds only if that exact runtime instance processes the registration; a
/// restart cannot redirect it to the successor runtime. On `Error`, the
/// connection is closed so its bound permit can be released.
pub fn admit_socket(
  sockets sockets: Sockets,
  owner owner: process.Pid,
  socket_id socket_id: String,
  send send: fn(String) -> Result(Nil, Nil),
  send_binary send_binary: fn(BitArray) -> Result(Nil, Nil),
  codec codec: Option(codec.Codec),
  seed seed: socket.ConnectSeed,
  close close: fn() -> Nil,
) -> Result(Nil, Nil) {
  use <- bool.lazy_guard(
    when: !beryl.app_dispatch(sockets).admit_socket(
      owner,
      socket_id,
      send,
      send_binary,
      codec,
      seed,
      close,
    ),
    return: fn() {
      close()
      Error(Nil)
    },
  )
  Ok(Nil)
}
