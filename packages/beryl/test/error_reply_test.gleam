//// Tests for channel error replies: `channel.ReplyError` must reach the
//// client as a `phx_reply` with `"status": "error"`, correlated to the
//// client's ref (Phoenix `push.receive("error", ...)`).

import beryl
import beryl/channel
import beryl/coordinator
import beryl/internal/unsupervised
import beryl/wire
import gleam/dynamic
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_with_error_channel() -> beryl.Channels {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
    |> channel.with_handle_in(fn(event, _payload, socket) {
      case event {
        "fail" -> channel.ReplyError(payload: channel.error("nope"), socket:)
        _ -> channel.NoReply(socket)
      }
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)
  channels
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

pub fn reply_error_sends_error_status_reply_test() {
  let channels = start_with_error_channel()
  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,\"ref-9\",\"room:lobby\",\"fail\",{}]",
  )

  let assert Ok(reply) = process.receive(socket, 500)
  reply
  |> string.contains("phx_reply")
  |> should.be_true
  reply
  |> string.contains("\"status\":\"error\"")
  |> should.be_true
  reply
  |> string.contains("nope")
  |> should.be_true
  reply
  |> string.contains("ref-9")
  |> should.be_true
}

pub fn event_on_unjoined_topic_gets_unmatched_topic_error_test() {
  let channels = start_with_error_channel()
  let socket = connect_socket(channels, "socket-1")

  // Push to a topic this socket never joined: Phoenix clients expect an
  // immediate error reply rather than a push timeout.
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,\"ref-1\",\"room:lobby\",\"hello\",{}]",
  )

  let assert Ok(reply) = process.receive(socket, 500)
  reply
  |> string.contains("\"status\":\"error\"")
  |> should.be_true
  reply
  |> string.contains("unmatched topic")
  |> should.be_true
  reply
  |> string.contains("ref-1")
  |> should.be_true
}

pub fn unjoined_event_without_ref_is_dropped_test() {
  let channels = start_with_error_channel()
  let socket = connect_socket(channels, "socket-1")

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,null,\"room:lobby\",\"hello\",{}]",
  )

  process.receive(socket, 100)
  |> should.be_error
}

pub fn reply_error_without_ref_is_dropped_test() {
  let channels = start_with_error_channel()
  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)

  // No ref on the inbound message: there is nothing to correlate an error
  // reply with, so no frame is sent.
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,null,\"room:lobby\",\"fail\",{}]",
  )

  process.receive(socket, 100)
  |> should.be_error
}
