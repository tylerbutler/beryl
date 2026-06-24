import beryl
import beryl/coordinator
import beryl/presence
import beryl/pubsub
import beryl/topic
import beryl/wire
import gleam/dynamic
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn register_test_channel(channels: beryl.Channels) -> Nil {
  let handler =
    coordinator.ChannelHandler(
      pattern: topic.parse_pattern("room:*"),
      join: fn(_topic, _payload, _ctx) {
        coordinator.JoinOkErased(reply: None, assigns: dynamic.nil())
      },
      handle_in: fn(_event, _payload, ctx) {
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      handle_binary: fn(_data, ctx) {
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      handle_info: fn(_message, ctx) {
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      terminate: fn(_reason, _ctx) { Nil },
    )

  let reply = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.RegisterChannel("room:*", handler, reply),
  )
  let assert Ok(Ok(Nil)) = process.receive(reply, 500)
  Nil
}

fn connect_socket(
  channels: beryl.Channels,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  let send = fn(message: String) -> Result(Nil, Nil) {
    process.send(sent, message)
    Ok(Nil)
  }

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      socket_id,
      send,
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  process.sleep(10)
  sent
}

fn join_topic(
  channels: beryl.Channels,
  socket_id: String,
  topic_name: String,
  sent: process.Subject(String),
) -> Nil {
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    socket_id,
    "[null,\"join-ref\",\"" <> topic_name <> "\",\"phx_join\",{}]",
  )

  let assert Ok(reply) = process.receive(sent, 500)
  reply
  |> string.contains("phx_reply")
  |> should.be_true
}

fn drain(subject: process.Subject(String)) -> Nil {
  case process.receive(subject, 0) {
    Ok(_) -> drain(subject)
    Error(_) -> Nil
  }
}

fn presence_diff() -> presence.Diff {
  presence.diff(
    joins: [
      #("room:lobby", [
        presence.PresenceEntry(
          pid: "socket-1",
          key: "user:1",
          meta: json.object([#("status", json.string("online"))]),
        ),
      ]),
    ],
    leaves: [],
  )
}

pub fn broadcast_from_local_only_excludes_socket_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register_test_channel(channels)

  let sender = connect_socket(channels, "sender-socket")
  let other = connect_socket(channels, "other-socket")
  join_topic(channels, "sender-socket", "room:lobby", sender)
  join_topic(channels, "other-socket", "room:lobby", other)
  drain(sender)
  drain(other)

  beryl.broadcast_from(
    channels,
    "sender-socket",
    "room:lobby",
    "typing",
    json.object([#("user", json.string("alice"))]),
  )

  let assert Ok(message) = process.receive(other, 500)
  message
  |> string.contains("typing")
  |> should.be_true

  process.receive(sender, 100)
  |> should.be_error
}

pub fn broadcast_from_with_pubsub_excludes_socket_on_remote_coordinator_test() {
  let assert Ok(ps) =
    pubsub.start(pubsub.config_with_scope("test_broadcast_from_pubsub"))
  let config = beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps)
  let assert Ok(origin_channels) = beryl.start(config)
  let assert Ok(remote_channels) = beryl.start(config)
  register_test_channel(origin_channels)
  register_test_channel(remote_channels)

  let remote_sender = connect_socket(remote_channels, "sender-socket")
  let remote_other = connect_socket(remote_channels, "other-socket")
  join_topic(remote_channels, "sender-socket", "room:lobby", remote_sender)
  join_topic(remote_channels, "other-socket", "room:lobby", remote_other)
  drain(remote_sender)
  drain(remote_other)

  beryl.broadcast_from(
    origin_channels,
    "sender-socket",
    "room:lobby",
    "typing",
    json.object([#("user", json.string("alice"))]),
  )

  let assert Ok(message) = process.receive(remote_other, 500)
  message
  |> string.contains("typing")
  |> should.be_true

  process.receive(remote_sender, 100)
  |> should.be_error
}

pub fn broadcast_presence_diff_local_delivers_phoenix_event_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register_test_channel(channels)

  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)
  drain(socket)

  beryl.broadcast_presence_diff(channels, "room:lobby", presence_diff())

  let assert Ok(message) = process.receive(socket, 500)
  message
  |> string.contains("presence_diff")
  |> should.be_true
  message
  |> string.contains("user:1")
  |> should.be_true
  message
  |> string.contains("metas")
  |> should.be_true
}

pub fn presence_track_can_broadcast_presence_diff_to_joined_socket_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register_test_channel(channels)

  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)
  drain(socket)

  let presence_config =
    presence.Config(
      pubsub: None,
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: Some(fn(diff) {
        beryl.broadcast_presence_diff(channels, "room:lobby", diff)
      }),
    )
  let assert Ok(p) = presence.start(presence_config)

  let _ =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("status", json.string("online"))]),
    )

  let assert Ok(message) = process.receive(socket, 500)
  message
  |> string.contains("presence_diff")
  |> should.be_true
  message
  |> string.contains("user:1")
  |> should.be_true
  message
  |> string.contains("metas")
  |> should.be_true
}

pub fn broadcast_presence_diff_with_pubsub_delivers_to_remote_coordinator_test() {
  let assert Ok(ps) =
    pubsub.start(pubsub.config_with_scope("test_presence_diff_pubsub"))
  let config = beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps)
  let assert Ok(origin_channels) = beryl.start(config)
  let assert Ok(remote_channels) = beryl.start(config)
  register_test_channel(origin_channels)
  register_test_channel(remote_channels)

  let remote_socket = connect_socket(remote_channels, "socket-1")
  join_topic(remote_channels, "socket-1", "room:lobby", remote_socket)
  drain(remote_socket)

  beryl.broadcast_presence_diff(origin_channels, "room:lobby", presence_diff())

  let assert Ok(message) = process.receive(remote_socket, 500)
  message
  |> string.contains("presence_diff")
  |> should.be_true
  message
  |> string.contains("user:1")
  |> should.be_true
  message
  |> string.contains("metas")
  |> should.be_true
}
