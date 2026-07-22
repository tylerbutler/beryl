//// Shared helpers for app-side dispatch (`beryl.start_app`) tests.
////
//// Sockets are driven through the public transport SPI so the tests
//// exercise the same path a real transport uses. Outbound frames are
//// captured in a subject per socket; the app's `update` can additionally
//// forward every event to an observer subject to make delivery visible.

import beryl
import beryl/event
import beryl/transport
import beryl/wire/codec
import gleam/erlang/process
import gleeunit/should

/// Connect a socket, returning the subject that captures its outbound
/// text frames.
pub fn connect(
  channels: beryl.Channels,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  transport.socket_connected(
    channels: channels,
    socket_id: socket_id,
    send: fn(message) {
      process.send(sent, message)
      Ok(Nil)
    },
    send_binary: fn(_data) { Ok(Nil) },
    seed: event.empty_seed(),
  )
  process.sleep(10)
  sent
}

/// Route a raw text frame the way a transport does: decode in the caller,
/// then hand the decoded message to the runtime.
pub fn route(channels: beryl.Channels, socket_id: String, raw: String) -> Nil {
  let assert Ok(msg) = codec.decode_text(transport.active_codec(channels))(raw)
  transport.route_decoded(channels, socket_id, msg)
}

/// Send a `phx_join` for a topic with the given join_ref/ref.
pub fn join(
  channels: beryl.Channels,
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
  channels: beryl.Channels,
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
  let assert Ok(frame) = process.receive(frames, 500)
  frame
}

/// Assert no frame arrives within 100ms.
pub fn recv_none(frames: process.Subject(String)) -> Nil {
  process.receive(frames, 100)
  |> should.be_error
  Nil
}

/// Receive the next observed event, failing after 500ms.
pub fn next_event(
  events: process.Subject(event.Event(msg)),
) -> event.Event(msg) {
  let assert Ok(ev) = process.receive(events, 500)
  ev
}
