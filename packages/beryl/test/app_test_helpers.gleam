//// Shared helpers for app-side dispatch (`beryl.child_spec`) tests.
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
import gleam/option.{type Option, None}
import gleam/otp/static_supervisor
import gleam/result
import gleeunit/should

/// Build and start an app-side dispatch subtree for tests.
pub fn start_app(
  config: beryl.Config,
  init init: fn(event.ConnectInfo(msg)) -> #(model, List(event.Effect)),
  update update: fn(model, event.Event(msg)) -> event.Next(model, msg),
) -> Result(beryl.Sockets, beryl.ConfigError) {
  use #(sockets, spec) <- result.try(beryl.child_spec(config, init:, update:))
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  Ok(sockets)
}

/// Start an app that forwards every event to `events` and accepts all
/// joins.
pub fn start_observed(
  config: beryl.Config,
  events: process.Subject(event.Event(Nil)),
) -> beryl.Sockets {
  let assert Ok(channels) =
    start_app(config, init: fn(_info) { #(Nil, []) }, update: fn(model, ev) {
      process.send(events, ev)
      case ev {
        event.Join(_, _, ref) ->
          event.Next(model, [event.AcceptJoin(ref, None)])
        _ -> event.Next(model, [])
      }
    })
  channels
}

/// Connect a socket, returning the subject that captures its outbound
/// text frames.
pub fn connect(
  channels: beryl.Sockets,
  socket_id: String,
) -> process.Subject(String) {
  connect_with_seed_and_close(channels, socket_id, event.empty_seed(), fn() {
    Nil
  })
}

pub fn connect_with_close(
  channels: beryl.Sockets,
  socket_id: String,
  close: fn() -> Nil,
) -> process.Subject(String) {
  connect_with_seed_and_close(channels, socket_id, event.empty_seed(), close)
}

/// Connect a socket with an explicit `ConnectSeed` (e.g. to assert that
/// transport-provided metadata reaches the app's `init` via
/// `ConnectInfo.seed`), returning the subject that captures its outbound
/// text frames.
pub fn connect_with_seed(
  channels: beryl.Sockets,
  socket_id: String,
  seed: event.ConnectSeed,
) -> process.Subject(String) {
  connect_with_seed_and_close(channels, socket_id, seed, fn() { Nil })
}

/// Connect a socket with an explicit per-socket codec, returning the
/// subject that captures its outbound text frames.
pub fn connect_with_codec(
  channels: beryl.Sockets,
  socket_id: String,
  socket_codec: Option(codec.Codec),
) -> process.Subject(String) {
  admit(channels, socket_id, socket_codec, event.empty_seed(), fn() { Nil })
}

fn connect_with_seed_and_close(
  channels: beryl.Sockets,
  socket_id: String,
  seed: event.ConnectSeed,
  close: fn() -> Nil,
) -> process.Subject(String) {
  admit(channels, socket_id, None, seed, close)
}

fn admit(
  channels: beryl.Sockets,
  socket_id: String,
  socket_codec: Option(codec.Codec),
  seed: event.ConnectSeed,
  close: fn() -> Nil,
) -> process.Subject(String) {
  let sent = process.new_subject()
  let owner = transport.connection_owner(channels)
  transport.admit_socket(
    sockets: channels,
    owner: owner,
    socket_id: socket_id,
    send: fn(message) {
      process.send(sent, message)
      Ok(Nil)
    },
    send_binary: fn(_data) { Ok(Nil) },
    codec: socket_codec,
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
