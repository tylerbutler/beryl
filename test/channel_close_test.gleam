//// Terminal channel event tests: the coordinator must tell clients when a
//// channel instance ends (`phx_close` for graceful stops, `phx_error` for
//// abnormal ones) so Phoenix clients leave the joined state and rejoin.

import beryl
import beryl/channel
import beryl/coordinator
import beryl/topic
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

fn register_stopping_channel(
  channels: beryl.Channels,
  stop_reason: channel.StopReason,
) -> Nil {
  let handler =
    coordinator.ChannelHandler(
      id: 0,
      pattern: topic.parse_pattern("room:*"),
      join: fn(_topic, _payload, _ctx) {
        coordinator.JoinOkErased(reply: None, assigns: dynamic.nil())
      },
      handle_in: fn(event, _payload, ctx) {
        case event {
          "stop" -> coordinator.StopErased(reason: stop_reason)
          _ -> coordinator.NoReplyErased(assigns: ctx.assigns)
        }
      },
      handle_binary: fn(_data, ctx) {
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      terminate: fn(_reason, _ctx) { Nil },
    )

  let reply = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.RegisterChannel("room:*", handler, reply),
  )
  let assert Ok(Ok(_)) = process.receive(reply, 500)
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

pub fn leave_sends_reply_then_phx_close_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register_stopping_channel(channels, channel.Normal)

  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,\"leave-1\",\"room:lobby\",\"phx_leave\",{}]",
  )

  let assert Ok(reply) = process.receive(socket, 500)
  reply
  |> string.contains("phx_reply")
  |> should.be_true
  reply
  |> string.contains("leave-1")
  |> should.be_true

  let assert Ok(close) = process.receive(socket, 500)
  close
  |> string.contains("phx_close")
  |> should.be_true
}

pub fn stop_with_error_sends_phx_error_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register_stopping_channel(channels, channel.Error("boom"))

  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,\"ref-2\",\"room:lobby\",\"stop\",{}]",
  )

  let assert Ok(frame) = process.receive(socket, 500)
  frame
  |> string.contains("phx_error")
  |> should.be_true
  frame
  |> string.contains("room:lobby")
  |> should.be_true
}

pub fn stop_with_normal_sends_phx_close_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  register_stopping_channel(channels, channel.Normal)

  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,\"ref-2\",\"room:lobby\",\"stop\",{}]",
  )

  let assert Ok(frame) = process.receive(socket, 500)
  frame
  |> string.contains("phx_close")
  |> should.be_true
}
