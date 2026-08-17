//// Shared helpers for the showcase channel tests.
////
//// Every test runs the **deployed** handler table — `showcase.handlers`,
//// the same list `showcase.main` registers — on a real socket system, and
//// drives it through beryl's public transport SPI (`beryl/transport`):
//// connect, decode a Phoenix frame in the caller, route it, disconnect.
//// So these assertions are made on the frames a browser would receive.

import beryl
import beryl/channel
import beryl/group
import beryl/socket
import beryl/transport
import beryl/wire
import beryl/wire/codec
import collab_docs/auth
import collab_docs/doc_store
import example_helpers/broadcast_hub as hub
import example_helpers/session_presence
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import showcase

/// A running showcase system plus the tenant secret its document channel
/// verifies join tokens against.
pub type System {
  System(
    sockets: beryl.Sockets,
    secret: BitArray,
    presence: session_presence.Tracker,
  )
}

/// The captured outbound text frames of one connected socket.
pub type Frames =
  process.Subject(String)

/// Start a showcase system: the deployed handler table over a fresh
/// session-presence tracker, room group, document store, and broadcast hub.
///
/// Rate limits are deliberately left off: the deployed limits exist to
/// throttle a public demo, and a test that tripped them would be asserting
/// the limiter rather than the channels.
pub fn start(_replica: String) -> System {
  let presence_tracker = session_presence.start()
  let #(groups, groups_spec) = group.child_spec()
  let assert Ok(store) = doc_store.start()
  let assert Ok(broadcast_hub) = hub.start()
  let secret = auth.new_secret()

  // Errors only: the runtime's info/warn lines would bury the test output.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_logging(beryl.logging_config(
      level: beryl.ErrorLevel,
      include_payloads: False,
    ))

  let assert Ok(#(sockets, spec)) =
    channel.child_spec(
      config,
      handlers: showcase.handlers(showcase.Deps(
        presence: presence_tracker,
        groups: groups,
        store: store,
        secret: secret,
        hub: broadcast_hub,
      )),
    )

  session_presence.configure(presence_tracker, sockets)
  hub.bind(broadcast_hub, sockets)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(groups_spec)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")

  System(sockets: sockets, secret: secret, presence: presence_tracker)
}

/// Stop the socket runtime and test-only presence publisher.
pub fn stop(system: System) -> Nil {
  let assert Ok(Nil) = beryl.stop(system.sockets)
  session_presence.stop(system.presence)
}

/// Whether the test-only presence publisher is still running.
pub fn presence_is_running(system: System) -> Bool {
  session_presence.is_running(system.presence)
}

/// A tenant token the document channel accepts.
pub fn token(system: System, tenant: String) -> String {
  auth.sign_tenant(tenant, system.secret)
}

/// Connect a socket, returning the subject that captures its outbound text
/// frames.
pub fn connect(system: System, socket_id: String) -> Frames {
  let sent = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(system.sockets)
  transport.admit_socket(
    sockets: system.sockets,
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

/// Announce that a socket's connection closed.
pub fn disconnect(system: System, socket_id: String) -> Nil {
  transport.socket_disconnected(system.sockets, socket_id)
}

/// Route a raw text frame the way a transport does: decode in the caller,
/// then hand the decoded message to the runtime.
pub fn route(system: System, socket_id: String, raw: String) -> Nil {
  let assert Ok(decoded) =
    codec.decode_text(transport.active_codec(system.sockets))(raw)
    as "the test frame is valid phoenix wire format"
  transport.route_decoded(system.sockets, socket_id, decoded)
}

/// Send a `phx_join` carrying a raw JSON payload.
pub fn join(
  system: System,
  socket_id: String,
  topic: String,
  ref: String,
  payload: String,
) -> Nil {
  frame(system, socket_id, ref, ref, topic, "phx_join", payload)
}

/// Send a `phx_leave` for a topic.
pub fn leave(
  system: System,
  socket_id: String,
  topic: String,
  join_ref: String,
  ref: String,
) -> Nil {
  frame(system, socket_id, join_ref, ref, topic, "phx_leave", "{}")
}

/// Send a client event that asks for a reply.
pub fn push(
  system: System,
  socket_id: String,
  topic: String,
  event: String,
  ref: String,
  payload: String,
) -> Nil {
  frame(system, socket_id, "1", ref, topic, event, payload)
}

/// Send a client event with no ref, so no reply is expected.
pub fn push_refless(
  system: System,
  socket_id: String,
  topic: String,
  event: String,
  payload: String,
) -> Nil {
  route(
    system,
    socket_id,
    "[\"1\",null,\"" <> topic <> "\",\"" <> event <> "\"," <> payload <> "]",
  )
}

fn frame(
  system: System,
  socket_id: String,
  join_ref: String,
  ref: String,
  topic: String,
  event: String,
  payload: String,
) -> Nil {
  route(
    system,
    socket_id,
    "[\""
      <> join_ref
      <> "\",\""
      <> ref
      <> "\",\""
      <> topic
      <> "\",\""
      <> event
      <> "\","
      <> payload
      <> "]",
  )
}

/// Receive the next frame, failing after 500ms.
pub fn recv(frames: Frames) -> String {
  let assert Ok(sent) = process.receive(frames, 500) as "a frame was sent"
  sent
}

/// Receive frames until one contains every fragment, returning the frames
/// consumed on the way (the match last).
pub fn recv_until(frames: Frames, fragments: List(String)) -> List(String) {
  drain(frames, fragments, [])
}

/// Receive frames until one contains every fragment, returning that frame.
pub fn expect(frames: Frames, fragments: List(String)) -> String {
  let assert Ok(matched) = list.last(recv_until(frames, fragments))
    as "a matching frame was sent"
  matched
}

/// Collect every frame that arrives until the socket goes quiet for
/// 200ms. Use it when what matters is the *last* frame of a sequence.
pub fn drain_all(frames: Frames) -> List(String) {
  collect(frames, [])
}

fn collect(frames: Frames, seen: List(String)) -> List(String) {
  case process.receive(frames, 200) {
    Error(Nil) -> seen
    Ok(frame) -> collect(frames, list.append(seen, [frame]))
  }
}

/// Assert no frame arrives within 100ms.
pub fn expect_silence(frames: Frames) -> Nil {
  process.receive(frames, 100) |> should.be_error
  Nil
}

/// Whether a frame contains every fragment.
pub fn contains(frame: String, fragments: List(String)) -> Bool {
  list.all(fragments, string.contains(frame, _))
}

fn drain(
  frames: Frames,
  fragments: List(String),
  seen: List(String),
) -> List(String) {
  let next = recv(frames)
  let seen = list.append(seen, [next])
  case contains(next, fragments) {
    True -> seen
    False -> drain(frames, fragments, seen)
  }
}
