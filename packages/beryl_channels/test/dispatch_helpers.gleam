//// Shared helpers for the dispatch-adapter integration tests.
////
//// Sockets are driven through beryl's **public** transport SPI
//// (`beryl/transport`), so these tests exercise exactly the path a real
//// WebSocket transport uses: connect, decode a frame in the caller, route
//// it, disconnect. Outbound frames are captured per socket.

import beryl
import beryl/socket
import beryl/transport
import beryl/wire
import beryl/wire/codec
import beryl_channels
import beryl_channels/channel
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleeunit/should

/// The captured outbound text frames of one connected socket.
pub type Frames =
  process.Subject(String)

/// Build and start a supervised channel system for integration tests.
pub fn start(
  config: beryl.Config,
  handlers handlers: List(channel.Handler),
) -> beryl.Sockets {
  let assert Ok(#(sockets, spec)) =
    beryl_channels.child_spec(config, handlers: handlers)
    as "the handler table and config are valid"
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the channel supervision tree starts"
  sockets
}

/// Connect a socket, returning the subject that captures its outbound
/// text frames.
///
/// No settling delay is needed: admission is acknowledged by the exact
/// runtime owner before this function returns.
pub fn connect(
  channels: beryl.Sockets,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(channels)
  transport.admit_socket(
    sockets: channels,
    owner: owner,
    socket_id: socket_id,
    send: fn(message) {
      process.send(sent, message)
      Ok(Nil)
    },
    send_binary: fn(_data) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  sent
}

/// The Phoenix framing minus its binary decoder, so raw binary frames take
/// the per-topic fan-out path and arrive as `Binary` inputs instead of
/// being rejected at decode.
pub fn text_only_codec() -> codec.Codec {
  codec.new(
    decode_text: wire.decode_message,
    encode_reply: wire.reply_json,
    encode_push: wire.push,
    encode_heartbeat_reply: wire.heartbeat_reply,
  )
  |> codec.with_close_encoder(wire.channel_close)
  |> codec.with_error_encoder(wire.channel_error)
}

/// A stable string for a stop reason, for trace assertions.
pub fn reason_name(reason: socket.StopReason) -> String {
  case reason {
    socket.Normal -> "normal"
    socket.Shutdown -> "shutdown"
    socket.HeartbeatTimeout -> "heartbeat_timeout"
    socket.Errored(detail) -> "errored:" <> detail
  }
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
  join_with(channels, socket_id, topic_name, join_ref, ref, "{}")
}

/// Send a `phx_join` carrying a raw JSON payload.
pub fn join_with(
  channels: beryl.Sockets,
  socket_id: String,
  topic_name: String,
  join_ref: String,
  ref: String,
  payload: String,
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
      <> "\",\"phx_join\","
      <> payload
      <> "]",
  )
}

/// Send a `phx_leave` for a topic.
pub fn leave(
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
      <> "\",\"phx_leave\",{}]",
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
