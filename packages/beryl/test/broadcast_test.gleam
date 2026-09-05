//// Broadcast semantics on the app runtime handle: `broadcast_from`
//// exclusion (local and across PubSub), and Phoenix `presence_diff`
//// broadcasts (local and across PubSub).

import app_test_helper
import beryl
import beryl/presence
import beryl/pubsub
import beryl/socket.{AcceptJoin, Binary, Closed, Info, Join, Message, Next}
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gleeunit/should
import test_helper

/// Start an app system that accepts every join.
fn start_accepting_app(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      config,
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, option.None)])
          Message(_, _, _, _) | Binary(_, _) | Closed(_, _) | Info(_) ->
            Next(model, [])
        }
      },
    )
  channels
}

fn join_topic(
  channels: beryl.Sockets,
  socket_id: String,
  topic_name: String,
  frames: process.Subject(String),
) -> Nil {
  app_test_helper.join(channels, socket_id, topic_name, "join-ref", "join-ref")
  let reply = app_test_helper.recv(frames)
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
          session_id: "socket-1",
          key: "user:1",
          meta: json.object([#("status", json.string("online"))]),
        ),
      ]),
    ],
    leaves: [],
  )
}

pub fn broadcast_from_local_only_excludes_socket_test() -> Nil {
  let channels = start_accepting_app(beryl.config(wire.phoenix_codec()))

  let sender = app_test_helper.connect(channels, "sender-socket")
  let other = app_test_helper.connect(channels, "other-socket")
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

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn broadcast_from_with_pubsub_excludes_socket_on_remote_runtime_test() -> Nil {
  let pubsub_instance =
    pubsub.start(pubsub.config_with_scope("test_broadcast_from_pubsub"))
  let config =
    beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(pubsub_instance)
  let origin_channels = start_accepting_app(config)
  let remote_channels = start_accepting_app(config)

  let remote_sender = app_test_helper.connect(remote_channels, "sender-socket")
  let remote_other = app_test_helper.connect(remote_channels, "other-socket")
  join_topic(remote_channels, "sender-socket", "room:lobby", remote_sender)
  join_topic(remote_channels, "other-socket", "room:lobby", remote_other)
  drain(remote_sender)
  drain(remote_other)
  test_helper.wait_until(
    fn() { pubsub.subscriber_count(pubsub_instance, "room:lobby") == 1 },
    1000,
    10,
  )

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

  let _ = beryl.stop(origin_channels)
  let assert Ok(Nil) = beryl.stop(remote_channels)
  Nil
}

pub fn broadcast_presence_diff_local_delivers_phoenix_event_test() -> Nil {
  let channels = start_accepting_app(beryl.config(wire.phoenix_codec()))

  let socket = app_test_helper.connect(channels, "socket-1")
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

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn presence_track_can_broadcast_presence_diff_to_joined_socket_test() -> Nil {
  let channels = start_accepting_app(beryl.config(wire.phoenix_codec()))

  let socket = app_test_helper.connect(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)
  drain(socket)

  let presence_config =
    presence.default_config("node1")
    |> presence.with_on_diff(fn(diff) {
      beryl.broadcast_presence_diff(channels, "room:lobby", diff)
    })
  let assert Ok(presence_handle) = presence.start(presence_config)

  let _ =
    presence.track(
      presence_handle,
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

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn broadcast_presence_diff_with_pubsub_delivers_to_remote_runtime_test() -> Nil {
  let pubsub_instance =
    pubsub.start(pubsub.config_with_scope("test_presence_diff_pubsub"))
  let config =
    beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(pubsub_instance)
  let origin_channels = start_accepting_app(config)
  let remote_channels = start_accepting_app(config)

  let remote_socket = app_test_helper.connect(remote_channels, "socket-1")
  join_topic(remote_channels, "socket-1", "room:lobby", remote_socket)
  drain(remote_socket)
  test_helper.wait_until(
    fn() { pubsub.subscriber_count(pubsub_instance, "room:lobby") == 1 },
    1000,
    10,
  )

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

  let _ = beryl.stop(origin_channels)
  let assert Ok(Nil) = beryl.stop(remote_channels)
  Nil
}
