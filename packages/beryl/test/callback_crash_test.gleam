//// Crash isolation tests: a panicking channel callback must terminate only
//// the offending channel, never the shared coordinator.

import beryl
import beryl/channel
import beryl/coordinator
import beryl/topic
import beryl/wire
import gleam/dynamic
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn register_channel(
  channels: beryl.Channels,
  handler: coordinator.ChannelHandler,
) -> Int {
  let reply = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.RegisterChannel("room:*", handler, reply),
  )
  let assert Ok(Ok(id)) = process.receive(reply, 500)
  id
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

fn assert_heartbeat_answered(
  channels: beryl.Channels,
  socket_id: String,
  sent: process.Subject(String),
) -> Nil {
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    socket_id,
    "[null,\"hb-1\",\"phoenix\",\"heartbeat\",{}]",
  )
  let assert Ok(reply) = process.receive(sent, 500)
  reply
  |> string.contains("phx_reply")
  |> should.be_true
}

fn crashing_handle_in_handler(
  terminated: process.Subject(channel.StopReason),
) -> coordinator.ChannelHandler {
  coordinator.ChannelHandler(
    id: 0,
    pattern: topic.parse_pattern("room:*"),
    join: fn(_topic, _payload, _ctx) {
      coordinator.JoinOkErased(reply: None, assigns: dynamic.nil())
    },
    handle_in: fn(_event, _payload, _ctx) { panic as "handle_in boom" },
    handle_binary: fn(_data, ctx) {
      coordinator.NoReplyErased(assigns: ctx.assigns)
    },
    terminate: fn(reason, _ctx) { process.send(terminated, reason) },
  )
}

pub fn handle_in_crash_terminates_channel_but_not_coordinator_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let terminated = process.new_subject()
  let _id = register_channel(channels, crashing_handle_in_handler(terminated))

  let crasher = connect_socket(channels, "crash-socket")
  let other = connect_socket(channels, "other-socket")
  join_topic(channels, "crash-socket", "room:lobby", crasher)
  join_topic(channels, "other-socket", "room:lobby", other)
  drain(crasher)
  drain(other)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "crash-socket",
    "[null,\"ref-2\",\"room:lobby\",\"boom\",{}]",
  )

  // The crashing channel's terminate ran with an Error reason
  let assert Ok(channel.Errored(_)) = process.receive(terminated, 500)

  // The client is told its channel instance died
  let assert Ok(error_frame) = process.receive(crasher, 500)
  error_frame
  |> string.contains("phx_error")
  |> should.be_true

  // The coordinator survived: broadcasts still reach the other socket
  beryl.broadcast(channels, "room:lobby", "still_alive", json.object([]))
  let assert Ok(message) = process.receive(other, 500)
  message
  |> string.contains("still_alive")
  |> should.be_true

  // The crashed channel was torn down: its socket is unsubscribed
  process.receive(crasher, 100)
  |> should.be_error
}

pub fn join_crash_sends_error_reply_and_coordinator_survives_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler =
    coordinator.ChannelHandler(
      id: 0,
      pattern: topic.parse_pattern("room:*"),
      join: fn(_topic, _payload, _ctx) { panic as "join boom" },
      handle_in: fn(_event, _payload, ctx) {
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      handle_binary: fn(_data, ctx) {
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      terminate: fn(_reason, _ctx) { Nil },
    )
  let _id = register_channel(channels, handler)

  let socket = connect_socket(channels, "socket-1")
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,\"ref-1\",\"room:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(reply) = process.receive(socket, 500)
  reply
  |> string.contains("\"error\"")
  |> should.be_true
  reply
  |> string.contains("join crashed")
  |> should.be_true

  assert_heartbeat_answered(channels, "socket-1", socket)
}

pub fn terminate_crash_does_not_kill_coordinator_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler =
    coordinator.ChannelHandler(
      id: 0,
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
      terminate: fn(_reason, _ctx) { panic as "terminate boom" },
    )
  let _id = register_channel(channels, handler)

  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)
  drain(socket)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[null,\"leave-1\",\"room:lobby\",\"phx_leave\",{}]",
  )

  // The leave reply is still delivered despite the crashing terminate
  let assert Ok(reply) = process.receive(socket, 500)
  reply
  |> string.contains("phx_reply")
  |> should.be_true

  // Followed by the phx_close for the terminated channel
  let assert Ok(close) = process.receive(socket, 500)
  close
  |> string.contains("phx_close")
  |> should.be_true

  assert_heartbeat_answered(channels, "socket-1", socket)
}

pub fn handle_info_crash_terminates_channel_not_coordinator_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let terminated = process.new_subject()
  let id = register_channel(channels, crashing_handle_in_handler(terminated))

  let socket = connect_socket(channels, "socket-1")
  join_topic(channels, "socket-1", "room:lobby", socket)
  drain(socket)

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.HandleInfo("socket-1", "room:lobby", id, fn(_ctx) {
      panic as "info boom"
    }),
  )

  let assert Ok(channel.Errored(_)) = process.receive(terminated, 500)

  // The client is told its channel instance died
  let assert Ok(error_frame) = process.receive(socket, 500)
  error_frame
  |> string.contains("phx_error")
  |> should.be_true

  assert_heartbeat_answered(channels, "socket-1", socket)
}
