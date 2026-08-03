//// Transport SPI — the contract between beryl core and WebSocket transport
//// implementations such as the `beryl_mist` package.
////
//// Transports built on `gleam/http` requests use `beryl/transport/server`,
//// which layers the upgrade admission pipeline, connection lifecycle, and
//// inbound frame pipeline on top of this module. The functions here are the
//// low-level contract that pipeline is built on: announce sockets
//// (`socket_connected`, `register_closer`, `socket_disconnected`), route
//// inbound frames (`route_decoded`, `route_binary`) decoded with the codec
//// from `active_codec` (see `beryl/wire/codec`), and tie connection
//// lifetimes to the owning runtime (`runtime_pid`).

import beryl.{type Sockets}
import beryl/socket.{type ConnectSeed}
import beryl/wire/codec.{type Codec, type Inbound}
import gleam/erlang/process

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
  beryl.app_dispatch(sockets).socket_connected(
    socket_id,
    send,
    send_binary,
    seed,
  )
}

/// Register a function that force-closes the socket's underlying connection
/// so the runtime can actively evict it (e.g. heartbeat timeout) instead
/// of leaving a zombie socket whose frames are silently dropped.
pub fn register_closer(
  sockets sockets: Sockets,
  socket_id socket_id: String,
  close close: fn() -> Nil,
) -> Nil {
  beryl.app_dispatch(sockets).register_closer(socket_id, close)
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
  message message: Inbound,
) -> Nil {
  beryl.app_dispatch(sockets).route_decoded(socket_id, message)
}

/// Route a raw binary frame. When the codec has a binary decoder the frame
/// is decoded in the runtime and dispatched like any inbound message;
/// otherwise it fans out to the socket's joined topics as `Binary` events
/// delivered to `update`.
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
pub fn active_codec(sockets: Sockets) -> Codec {
  beryl.configured_codec(sockets)
}

// --- Connection limits ---

/// A held per-IP connection slot, acquired by the admission pipeline in
/// `beryl/transport/server` (`server.upgrade`) and released by
/// `server.close_connection` / `server.release_slot_on_failed_handshake`.
///
/// Opaque so Beryl can restructure the connection limiter without breaking
/// transport authors. When no per-IP limit is configured the permit is an
/// admit-everything placeholder and releasing it is a no-op.
pub type ConnectionPermit =
  beryl.ConnectionPermit

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
