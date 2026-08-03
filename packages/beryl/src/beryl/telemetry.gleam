//// Typed internal telemetry primitives.
////
//// Event constructors intentionally accept only closed vocabularies. This
//// prevents callers from putting topics, socket IDs, payloads, or arbitrary
//// error text into metadata.

import gleam/bool
import gleam/int

/// Transport implementations supported by beryl's telemetry schema.
pub type Transport {
  Mist
  Ewe
}

/// Terminal outcomes shared by telemetry events.
pub type Outcome {
  Success
  Rejected
  Dropped
  RateLimited
  Invalid
  Failed
}

/// WebSocket frame kinds.
pub type FrameKind {
  TextFrame
  BinaryFrame
}

/// Channel message callback kinds.
pub type MessageKind {
  TextMessage
  BinaryMessage
  InfoMessage
  HeartbeatMessage
}

/// Closed callback-result vocabulary.
pub type CallbackResult {
  NoReply
  Reply
  ReplyError
  Push
  Stop
  CallbackFailed
}

/// Closed socket-disconnect reason vocabulary.
pub type DisconnectReason {
  ClientClosed
  TransportClosed
  HeartbeatTimeout
  ServerShutdown
  DisconnectFailed
}

/// Whether a broadcast originated on this node or a remote node.
pub type BroadcastOrigin {
  Local
  Remote
}

/// Stable, low-cardinality beryl telemetry events.
pub type Event {
  TransportUpgradeStop(duration: Int, transport: Transport, outcome: Outcome)
  TransportFrameStop(
    duration: Int,
    bytes: Int,
    transport: Transport,
    kind: FrameKind,
    outcome: Outcome,
  )
  SocketConnected
  SocketDisconnected(
    duration: Int,
    joined_channels: Int,
    reason: DisconnectReason,
  )
  ChannelJoinStop(duration: Int, outcome: Outcome)
  ChannelMessageStop(
    duration: Int,
    kind: MessageKind,
    outcome: Outcome,
    callback_result: CallbackResult,
  )
  BroadcastStop(
    duration: Int,
    recipients: Int,
    send_failures: Int,
    origin: BroadcastOrigin,
  )
}

@external(erlang, "beryl_telemetry_ffi", "execute")
fn execute(event: Event) -> Nil

@external(erlang, "beryl_telemetry_ffi", "monotonic_time")
fn monotonic_time() -> Int

@external(erlang, "beryl_telemetry_ffi", "mailbox_length")
fn current_mailbox_length() -> Int

/// Emit a typed event when telemetry is enabled.
///
/// The disabled branch does not call the FFI or construct measurements and
/// metadata maps.
pub fn emit(enabled: Bool, event: Event) -> Nil {
  use <- bool.guard(when: !enabled, return: Nil)
  execute(event)
}

/// Capture a monotonic timestamp in the VM's native time unit.
pub fn start_time() -> Int {
  monotonic_time()
}

/// Return elapsed monotonic time in the VM's native time unit.
pub fn duration_since(started_at: Int) -> Int {
  monotonic_time()
  |> fn(now) { int.max(now - started_at, 0) }
}

/// Return the calling process's current mailbox length.
pub fn mailbox_length() -> Int {
  current_mailbox_length()
}
