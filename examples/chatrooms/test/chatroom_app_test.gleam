import beryl
import beryl/channel
import beryl/group
import beryl/socket
import beryl/transport
import beryl/wire
import beryl/wire/codec
import chatroom/app
import example_helper/broadcast_hub
import example_helper/session_presence
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should

fn start() -> #(beryl.Sockets, session_presence.Tracker) {
  let presence = session_presence.start()
  let #(groups, groups_specification) = group.child_spec()
  let assert Ok(hub) = broadcast_hub.start()
  let context = app.Context(presence: presence, groups: groups, hub: hub)
  let assert Ok(#(sockets, specification)) =
    channel.child_spec(
      beryl.config(wire.phoenix_codec()),
      handlers: app.handlers(context),
    )
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(groups_specification)
    |> static_supervisor.add(specification)
    |> static_supervisor.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  broadcast_hub.bind(hub, sockets)
  #(sockets, presence)
}

fn connect(
  sockets: beryl.Sockets,
  socket_id: String,
) -> process.Subject(String) {
  let frames = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(sockets)
  transport.admit_socket(
    sockets: sockets,
    owner: owner,
    socket_id: socket_id,
    send: fn(frame) {
      process.send(frames, frame)
      Ok(Nil)
    },
    send_binary: fn(_frame) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  frames
}

fn route(sockets: beryl.Sockets, socket_id: String, frame: String) -> Nil {
  let assert Ok(decoded) =
    codec.decode_text(transport.active_codec(sockets))(frame)
  transport.route_decoded(sockets, socket_id, decoded)
}

fn recv(frames: process.Subject(String)) -> String {
  let assert Ok(frame) = process.receive(frames, 500)
  frame
}

pub fn lobby_join_is_accepted_test() -> Nil {
  let #(sockets, _presence) = start()
  let frames = connect(sockets, "lobby-socket")
  route(sockets, "lobby-socket", "[\"jr-1\",\"r-1\",\"lobby\",\"phx_join\",{}]")

  recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn unrelated_topic_is_rejected_test() -> Nil {
  let #(sockets, _presence) = start()
  let frames = connect(sockets, "unknown-socket")
  route(
    sockets,
    "unknown-socket",
    "[\"jr-1\",\"r-1\",\"notifications:alice\",\"phx_join\",{}]",
  )

  recv(frames)
  |> string.contains("\"reason\":\"unmatched topic\"")
  |> should.be_true
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn accepted_room_join_tracks_presence_and_updates_lobby_test() -> Nil {
  let #(sockets, presence) = start()
  let lobby = connect(sockets, "lobby-socket")
  route(sockets, "lobby-socket", "[\"jr-l\",\"r-l\",\"lobby\",\"phx_join\",{}]")
  let _lobby_join = recv(lobby)

  let room = connect(sockets, "room-socket")
  route(
    sockets,
    "room-socket",
    "[\"jr-r\",\"r-r\",\"room:general\",\"phx_join\",{\"username\":\"Alice\"}]",
  )

  recv(room) |> string.contains("\"status\":\"ok\"") |> should.be_true
  recv(room) |> string.contains("\"new_msg\"") |> should.be_true
  recv(lobby) |> string.contains("\"rooms_changed\"") |> should.be_true
  session_presence.count(presence, "room:general") |> should.equal(1)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn missing_room_is_rejected_test() -> Nil {
  let #(sockets, presence) = start()
  let frames = connect(sockets, "room-socket")
  route(
    sockets,
    "room-socket",
    "[\"jr-r\",\"r-r\",\"room:missing\",\"phx_join\",{}]",
  )

  recv(frames) |> string.contains("Room not found") |> should.be_true
  session_presence.count(presence, "room:missing") |> should.equal(0)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
