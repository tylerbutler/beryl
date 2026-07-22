//// Duplicate-join and join_ref staleness tests, matching Phoenix semantics:
//// a rejoin replaces the previous channel instance (terminating it first),
//// and messages carrying a previous instance's join_ref are dropped.

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

fn replying_instance(
  terminated: process.Subject(channel.StopReason),
) -> coordinator.JoinedChannel {
  coordinator.JoinedChannel(
    handle_in: fn(_event, _payload, _ctx) {
      coordinator.ReplyErased(
        event: "reply",
        payload: json.object([]),
        next: replying_instance(terminated),
      )
    },
    handle_binary: fn(_data, _ctx) {
      coordinator.NoReplyErased(next: replying_instance(terminated))
    },
    handle_info: fn(_message, _ctx) {
      coordinator.NoReplyErased(next: replying_instance(terminated))
    },
    terminate: fn(reason, _ctx) { process.send(terminated, reason) },
  )
}

fn register_channel(
  channels: beryl.Channels,
  terminated: process.Subject(channel.StopReason),
) -> Nil {
  let handler =
    coordinator.ChannelHandler(
      id: 0,
      pattern: topic.parse_pattern("room:*"),
      join: fn(_topic, _payload, _connect_assigns, _ctx) {
        coordinator.JoinOkErased(
          reply: None,
          channel: replying_instance(terminated),
        )
      },
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

fn join_with_ref(
  channels: beryl.Channels,
  socket_id: String,
  join_ref: String,
) -> Nil {
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    socket_id,
    "[\""
      <> join_ref
      <> "\",\""
      <> join_ref
      <> "\",\"room:lobby\",\"phx_join\",{}]",
  )
}

pub fn duplicate_join_terminates_previous_instance_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let terminated = process.new_subject()
  register_channel(channels, terminated)

  let socket = connect_socket(channels, "socket-1")
  join_with_ref(channels, "socket-1", "j1")
  let assert Ok(first_reply) = process.receive(socket, 500)
  first_reply |> string.contains("phx_reply") |> should.be_true

  // Rejoin the same topic: the old instance terminates (phx_close), then the
  // new join is accepted.
  join_with_ref(channels, "socket-1", "j2")

  let assert Ok(reason) = process.receive(terminated, 500)
  reason |> should.equal(channel.Normal)

  let assert Ok(close_frame) = process.receive(socket, 500)
  close_frame |> string.contains("phx_close") |> should.be_true
  // The close is attributed to the old instance's join_ref.
  close_frame |> string.contains("j1") |> should.be_true

  let assert Ok(second_reply) = process.receive(socket, 500)
  second_reply |> string.contains("phx_reply") |> should.be_true
  second_reply |> string.contains("j2") |> should.be_true
}

pub fn stale_join_ref_messages_are_dropped_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let terminated = process.new_subject()
  register_channel(channels, terminated)

  let socket = connect_socket(channels, "socket-1")
  join_with_ref(channels, "socket-1", "j1")
  let assert Ok(_first_reply) = process.receive(socket, 500)
  join_with_ref(channels, "socket-1", "j2")
  let assert Ok(_terminated) = process.receive(terminated, 500)
  let assert Ok(_close) = process.receive(socket, 500)
  let assert Ok(_second_reply) = process.receive(socket, 500)

  // An event from the old instance (join_ref j1) must not reach the channel.
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[\"j1\",\"ref-1\",\"room:lobby\",\"ping\",{}]",
  )
  process.receive(socket, 100) |> should.be_error

  // The current instance (j2) still works.
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[\"j2\",\"ref-2\",\"room:lobby\",\"ping\",{}]",
  )
  let assert Ok(reply) = process.receive(socket, 500)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("ref-2") |> should.be_true
  // The reply echoes the channel's join_ref, matching Phoenix.
  reply |> string.contains("j2") |> should.be_true
}

pub fn stale_join_ref_leave_is_ignored_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let terminated = process.new_subject()
  register_channel(channels, terminated)

  let socket = connect_socket(channels, "socket-1")
  join_with_ref(channels, "socket-1", "j1")
  let assert Ok(_first_reply) = process.receive(socket, 500)
  join_with_ref(channels, "socket-1", "j2")
  let assert Ok(_terminated) = process.receive(terminated, 500)
  let assert Ok(_close) = process.receive(socket, 500)
  let assert Ok(_second_reply) = process.receive(socket, 500)

  // A leave from the old instance must not close the new one.
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[\"j1\",\"leave-1\",\"room:lobby\",\"phx_leave\",{}]",
  )
  process.receive(terminated, 100) |> should.be_error

  // The current instance still handles events.
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-1",
    "[\"j2\",\"ref-2\",\"room:lobby\",\"ping\",{}]",
  )
  let assert Ok(reply) = process.receive(socket, 500)
  reply |> string.contains("phx_reply") |> should.be_true
}
