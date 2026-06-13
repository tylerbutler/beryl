import beryl
import beryl/bridge
import beryl/channel
import beryl/coordinator
import beryl/wire
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gleeunit/should
import test_helpers.{wait_until}

fn start_channels_with_socket(
  socket_id: String,
) -> #(beryl.Channels, process.Subject(String)) {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      socket_id,
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
    ),
  )

  #(channels, sent_messages)
}

fn notify_channel() -> channel.Channel(Nil, Dynamic) {
  channel.new(fn(_topic, _payload, socket) {
    channel.JoinOk(reply: option.None, socket: socket)
  })
  |> channel.with_handle_info(fn(message, socket) {
    case decode.run(message, decode.string) {
      Ok(text) ->
        channel.Push(
          "server_notify",
          json.object([#("text", json.string(text))]),
          socket,
        )
      _ -> channel.NoReply(socket)
    }
  })
}

pub fn bridge_forwards_subject_values_to_handle_info_test() {
  let #(channels, sent_messages) = start_channels_with_socket("bridge-sock")

  beryl.register(channels, "room:*", notify_channel())
  |> should.equal(Ok(Nil))

  coordinator.route_message(
    channels.coordinator,
    "bridge-sock",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  // Bridge an external stream (here, a plain Subject standing in for a domain
  // actor) to this socket/topic, translating each value before forwarding.
  let b =
    bridge.start(
      channels: channels,
      socket_id: "bridge-sock",
      topic: "room:lobby",
      with: fn(n: Int) { "tick-" <> string.inspect(n) },
    )

  process.send(bridge.subject(b), 1)

  let assert Ok(push) = process.receive(sent_messages, 500)
  push |> string.contains("server_notify") |> should.be_true
  push |> string.contains("tick-1") |> should.be_true

  // A second value is forwarded too — the forwarder loops.
  process.send(bridge.subject(b), 2)
  let assert Ok(push2) = process.receive(sent_messages, 500)
  push2 |> string.contains("tick-2") |> should.be_true

  bridge.stop(b)
}

pub fn bridge_stop_tears_down_forwarder_test() {
  let #(channels, _sent) = start_channels_with_socket("bridge-stop-sock")

  let b =
    bridge.start(
      channels: channels,
      socket_id: "bridge-stop-sock",
      topic: "room:lobby",
      with: fn(x: String) { x },
    )

  let pid = bridge.pid(b)
  process.is_alive(pid) |> should.be_true

  bridge.stop(b)

  wait_until(fn() { !process.is_alive(pid) }, 1000, 10)
  process.is_alive(pid) |> should.be_false
}

pub fn bridge_cleans_up_when_owner_dies_test() {
  let #(channels, _sent) = start_channels_with_socket("bridge-owner-sock")

  let pid_back = process.new_subject()

  // Start the bridge from a short-lived owner process. When that process
  // exits, the monitored forwarder should exit too — no leak even without an
  // explicit stop.
  process.spawn_unlinked(fn() {
    let b =
      bridge.start(
        channels: channels,
        socket_id: "bridge-owner-sock",
        topic: "room:lobby",
        with: fn(x: String) { x },
      )
    process.send(pid_back, bridge.pid(b))
  })

  let assert Ok(forwarder) = process.receive(pid_back, 1000)

  wait_until(fn() { !process.is_alive(forwarder) }, 1000, 10)
  process.is_alive(forwarder) |> should.be_false
}
