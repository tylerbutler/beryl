//// Shared helpers for the dispatch-adapter integration tests.
////
//// Sockets are driven through beryl's **public** transport SPI
//// (`beryl/transport`), so these tests exercise exactly the path a real
//// WebSocket transport uses: connect, decode a frame in the caller, route
//// it, disconnect. Outbound frames are captured per socket.

import beryl
import beryl/socket
import beryl/transport
import beryl/wire/codec
import gleam/erlang/process
import gleeunit/should

/// Connect a socket, returning the subject that captures its outbound
/// text frames.
pub fn connect(
  channels: beryl.Sockets,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  transport.socket_connected(
    sockets: channels,
    socket_id: socket_id,
    send: fn(message) {
      process.send(sent, message)
      Ok(Nil)
    },
    send_binary: fn(_data) { Ok(Nil) },
    seed: socket.empty_seed(),
  )
  process.sleep(10)
  sent
}

/// Announce that a socket's connection closed.
pub fn disconnect(channels: beryl.Sockets, socket_id: String) -> Nil {
  transport.socket_disconnected(channels, socket_id)
}

/// Route a raw text frame the way a transport does: decode in the caller,
/// then hand the decoded message to the runtime.
pub fn route(channels: beryl.Sockets, socket_id: String, raw: String) -> Nil {
  let assert Ok(decoded) =
    codec.decode_text(transport.active_codec(channels))(raw)
    as "the test frame is valid phoenix wire format"
  transport.route_decoded(channels, socket_id, decoded)
}

/// Route a raw binary frame.
pub fn route_binary(
  channels: beryl.Sockets,
  socket_id: String,
  data: BitArray,
) -> Nil {
  transport.route_binary(channels, socket_id, data)
}

/// Send a `phx_join` for a topic with the given join_ref/ref.
pub fn join(
  channels: beryl.Sockets,
  socket_id: String,
  topic_name: String,
  join_ref: String,
  ref: String,
) -> Nil {
  route(
    channels,
    socket_id,
    "[\""
      <> join_ref
      <> "\",\""
      <> ref
      <> "\",\""
      <> topic_name
      <> "\",\"phx_join\",{}]",
  )
}

/// Send a user event on a topic with a reply ref.
pub fn push(
  channels: beryl.Sockets,
  socket_id: String,
  topic_name: String,
  event_name: String,
  ref: String,
) -> Nil {
  route(
    channels,
    socket_id,
    "[null,\""
      <> ref
      <> "\",\""
      <> topic_name
      <> "\",\""
      <> event_name
      <> "\",{}]",
  )
}

/// Receive the next captured frame, failing after 500ms.
pub fn recv(frames: process.Subject(String)) -> String {
  let assert Ok(frame) = process.receive(frames, 500) as "a frame was sent"
  frame
}

/// Assert no frame arrives within 100ms.
pub fn recv_none(frames: process.Subject(String)) -> Nil {
  process.receive(frames, 100) |> should.be_error
  Nil
}

/// Receive the next trace line recorded by a test channel, failing after
/// 500ms.
pub fn next_trace(trace: process.Subject(String)) -> String {
  let assert Ok(line) = process.receive(trace, 500) as "a trace was recorded"
  line
}

/// Assert no trace line is recorded within 100ms.
pub fn no_trace(trace: process.Subject(String)) -> Nil {
  process.receive(trace, 100) |> should.be_error
  Nil
}
