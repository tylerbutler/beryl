//// Fan-out scope: `push` is for the socket that asked, `broadcast`
//// reaches every socket on the topic, and `broadcast_from` reaches every
//// socket *except* the one whose callback ran — all on the channel's own
//// topic, and all in the order the actions were added.
////
//// The single-socket action tests can only observe an absence for
//// `broadcast_from`; these run two sockets, so the exclusion is proved by
//// what the other socket actually receives.

import beryl
import beryl/wire
import beryl_channels/channel
import dispatch_helper as helper
import gleam/json
import gleam/string
import gleeunit/should

/// A channel that fans one message out through all three send scopes.
fn fanout_handler() -> channel.Handler {
  channel.handler("room:*", fn(_info, _topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(state, _message) {
        channel.continue_with(
          state,
          channel.actions()
            |> channel.push("mine", json.int(1))
            |> channel.broadcast_from("others", json.int(2))
            |> channel.broadcast("everyone", json.int(3)),
        )
      })
    channel.accept(channel.joined(Nil, callbacks))
  })
}

fn start_two_sockets() -> #(beryl.Sockets, helper.Frames, helper.Frames) {
  let channels =
    helper.start(beryl.config(wire.phoenix_codec()), handlers: [
      fanout_handler(),
    ])

  let first = helper.connect(channels, "s1")
  let second = helper.connect(channels, "s2")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  helper.recv(first) |> string.contains("\"status\":\"ok\"") |> should.be_true
  helper.join(channels, "s2", "room:a", "jr-2", "r-2")
  helper.recv(second) |> string.contains("\"status\":\"ok\"") |> should.be_true

  #(channels, first, second)
}

pub fn push_reaches_only_the_socket_whose_callback_ran_test() {
  let #(channels, first, second) = start_two_sockets()

  helper.push(channels, "s1", "room:a", "go", "r-3")

  helper.recv(first) |> string.contains("\"mine\",1") |> should.be_true

  // The other socket sees the two fan-out sends and never the push.
  let others = helper.recv(second)
  others |> string.contains("\"others\",2") |> should.be_true
  others |> string.contains("\"mine\"") |> should.be_false
}

pub fn broadcast_from_excludes_the_sender_and_reaches_the_rest_test() {
  let #(channels, first, second) = start_two_sockets()

  helper.push(channels, "s1", "room:a", "go", "r-3")

  // Sending socket: push, then the plain broadcast. The
  // `broadcast_from` in between is not delivered back to it.
  helper.recv(first) |> string.contains("\"mine\",1") |> should.be_true
  helper.recv(first) |> string.contains("\"everyone\",3") |> should.be_true
  helper.recv_none(first)

  // Other socket: the excluded-sender broadcast *and* the plain one, in
  // the order the actions were added.
  helper.recv(second) |> string.contains("\"others\",2") |> should.be_true
  helper.recv(second) |> string.contains("\"everyone\",3") |> should.be_true
  helper.recv_none(second)
}

pub fn fan_out_is_scoped_to_the_channels_own_topic_test() {
  let #(channels, first, second) = start_two_sockets()

  // A second socket joins a *different* topic served by the same handler.
  helper.join(channels, "s2", "room:b", "jr-3", "r-3")
  helper.recv(second) |> string.contains("\"status\":\"ok\"") |> should.be_true

  helper.push(channels, "s1", "room:a", "go", "r-4")

  helper.recv(first) |> string.contains("\"room:a\",\"mine\"") |> should.be_true
  helper.recv(first)
  |> string.contains("\"room:a\",\"everyone\"")
  |> should.be_true
  helper.recv_none(first)

  // Every frame the other socket receives is for `room:a`; nothing leaked
  // onto `room:b`.
  helper.recv(second)
  |> string.contains("\"room:a\",\"others\"")
  |> should.be_true
  helper.recv(second)
  |> string.contains("\"room:a\",\"everyone\"")
  |> should.be_true
  helper.recv_none(second)
}
