import beryl
import beryl/channel
import beryl/coordinator
import beryl/wire
import beryl/wire/codec
import gleam/dynamic
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gleeunit/should

fn start_with_socket(socket_id) {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      socket_id,
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )
  #(channels, sent)
}

fn echo_channel() -> channel.Channel(Nil, info) {
  channel.new(fn(_t, _p, s) { channel.JoinOk(reply: option.None, socket: s) })
  |> channel.with_handle_in(fn(_e, _p, s) {
    channel.Push("echoed", json.object([]), s)
  })
}

// A topic-less event (empty topic) routes to the socket's single joined topic.
pub fn topicless_event_routes_to_single_join_test() {
  let #(channels, sent) = start_with_socket("s1")
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "s1",
    "[null,\"jr\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_) = process.receive(sent, 500)

  // event with empty topic — should fall back to room:lobby
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "s1",
    "[null,null,\"\",\"submitOp\",{}]",
  )
  let assert Ok(reply) = process.receive(sent, 500)
  reply |> string.contains("echoed") |> should.be_true
}

// With no join, a topic-less event is dropped (nothing sent back).
pub fn topicless_event_without_join_dropped_test() {
  let #(channels, sent) = start_with_socket("s2")
  let assert Ok(_) = beryl.register(channels, "room:*", echo_channel())
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "s2",
    "[null,null,\"\",\"submitOp\",{}]",
  )
  process.receive(sent, 200) |> should.be_error
  codec.Join |> should.equal(codec.Join)
}
