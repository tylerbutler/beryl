//// Shared helpers for supervised app-side dispatch (`beryl.child_spec`) tests.
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
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleeunit/should

/// A minimal app `init` that carries no model and produces no effects.
pub fn accepting_init(
  _info: socket.ConnectInfo(Nil),
) -> #(Nil, List(socket.Effect)) {
  #(Nil, [])
}

/// A minimal app `update` that accepts every join and ignores other inputs.
pub fn accepting_update(
  model: Nil,
  input: socket.Input(Nil),
) -> socket.Next(Nil) {
  case input {
    socket.Join(_, _, ref) -> socket.Next(model, [socket.AcceptJoin(ref, None)])
    _ -> socket.Next(model, [])
  }
}

/// Build and start an app-side dispatch subtree for tests.
pub fn start_app(
  config: beryl.Config,
  init init: fn(socket.ConnectInfo(msg)) -> #(model, List(socket.Effect)),
  update update: fn(model, socket.Input(msg)) -> socket.Next(model),
) -> Result(beryl.Sockets, beryl.ConfigError) {
  use #(sockets, spec) <- result.try(beryl.child_spec(config, init:, update:))
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  Ok(sockets)
}

/// Start a supervised app that accepts joins and forwards every input to
/// the observer subject.
pub fn start_observed(
  config: beryl.Config,
  inputs: process.Subject(socket.Input(Nil)),
) -> beryl.Sockets {
  let assert Ok(sockets) =
    start_app(config, init: accepting_init, update: fn(model, input) {
      process.send(inputs, input)
      accepting_update(model, input)
    })
  sockets
}

/// Return the live runtime pid backing a supervised sockets handle.
pub fn runtime_pid(sockets: beryl.Sockets) -> process.Pid {
  let assert Ok(pid) = beryl.app_runtime_pid(sockets)
  pid
}

/// Connect a socket, returning the subject that captures its outbound
/// text frames.
pub fn connect(
  channels: beryl.Sockets,
  socket_id: String,
) -> process.Subject(String) {
  connect_with_seed_and_close(channels, socket_id, socket.empty_seed(), fn() {
    Nil
  })
}

pub fn connect_with_close(
  channels: beryl.Sockets,
  socket_id: String,
  close: fn() -> Nil,
) -> process.Subject(String) {
  connect_with_seed_and_close(channels, socket_id, socket.empty_seed(), close)
}

fn connect_with_seed_and_close(
  channels: beryl.Sockets,
  socket_id: String,
  seed: socket.ConnectSeed,
  close: fn() -> Nil,
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
    seed: seed,
    close: close,
  )
  |> should.equal(Ok(Nil))
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

/// Send a join and assert its reply has status `"ok"`.
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
