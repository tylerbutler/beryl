//// Shared helpers for app-side dispatch (`beryl.start`) tests.
////
//// Sockets are driven through the public transport SPI so the tests
//// exercise the same path a real transport uses. Outbound frames are
//// captured in a subject per socket; the app's `update` can additionally
//// forward every event to an observer subject to make delivery visible.

import beryl
import beryl/socket
import beryl/transport
import beryl/wire/codec
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit/should

/// A minimal app `init` that carries no model and produces no effects.
/// Pair with `accepting_update` for a system that accepts every join.
pub fn accepting_init(
  _info: socket.ConnectInfo(Nil),
) -> #(Nil, List(socket.Effect)) {
  #(Nil, [])
}

/// A minimal app `update` that accepts every join and ignores every other
/// event.
pub fn accepting_update(
  model: Nil,
  ev: socket.Input(Nil),
) -> socket.Next(Nil, Nil) {
  case ev {
    socket.Join(_, _, ref) -> socket.Next(model, [socket.AcceptJoin(ref, None)])
    _ -> socket.Next(model, [])
  }
}

/// Start an app system that accepts every join and forwards every event to
/// the `events` observer subject.
pub fn start_observed(
  config: beryl.Config,
  events: process.Subject(socket.Input(Nil)),
) -> beryl.Sockets {
  let assert Ok(channels) =
    beryl.start(config, init: accepting_init, update: fn(model, ev) {
      process.send(events, ev)
      accepting_update(model, ev)
    })
  channels
}

/// The pid of the runtime backing `channels`, asserting it is running.
pub fn runtime_pid(channels: beryl.Sockets) -> process.Pid {
  let assert Ok(pid) = beryl.app_runtime_pid(channels)
  pid
}

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

/// Route a raw text frame the way a transport does: decode in the caller,
/// then hand the decoded message to the runtime.
pub fn route(channels: beryl.Sockets, socket_id: String, raw: String) -> Nil {
  let assert Ok(msg) = codec.decode_text(transport.active_codec(channels))(raw)
  transport.route_decoded(channels, socket_id, msg)
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

/// Send a `phx_join` for a topic and assert the reply has status "ok".
pub fn join_ok(
  channels: beryl.Sockets,
  frames: process.Subject(String),
  socket_id: String,
  topic_name: String,
  join_ref: String,
  ref: String,
) -> Nil {
  join(channels, socket_id, topic_name, join_ref, ref)
  recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
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
  events: process.Subject(socket.Input(msg)),
) -> socket.Input(msg) {
  let assert Ok(ev) = process.receive(events, 500)
  ev
}
