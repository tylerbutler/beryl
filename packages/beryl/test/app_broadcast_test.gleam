//// Distributed broadcast for app-side dispatch: a `Broadcast` effect on one
//// runtime reaches a topic's subscribers on another runtime sharing the same
//// PubSub scope, and a `BroadcastFrom` effect excludes the sending socket
//// while still fanning out locally and across runtimes.

import app_test_helpers as h
import beryl
import beryl/pubsub
import beryl/socket.{AcceptJoin, Broadcast, BroadcastFrom, Join, Message, Next}
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_runtime(scope: String) -> beryl.Sockets {
  let ps = pubsub.start(pubsub.config_with_scope(scope))
  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(topic, "cast", _payload, _ref) ->
            Next(model, [Broadcast(topic, "shout", json.object([]))])
          Message(topic, "cast_others", _payload, _ref) ->
            Next(model, [BroadcastFrom(topic, "shout", json.object([]))])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

fn join_lobby(
  channels: beryl.Sockets,
  socket_id: String,
  join_ref: String,
) -> process.Subject(String) {
  let frames = h.connect(channels, socket_id)
  h.join_ok(channels, frames, socket_id, "room:lobby", join_ref, "r-1")
  frames
}

pub fn broadcast_reaches_subscribers_across_runtimes_test() {
  let scope = "app_bcast_cast"
  let node_a = start_runtime(scope)
  let node_b = start_runtime(scope)

  let observer_b = join_lobby(node_b, "b-observer", "jr-b")
  let sender_a = join_lobby(node_a, "a-sender", "jr-a")
  // Let node_b's join propagate to node_a's pubsub membership.
  process.sleep(50)

  h.push(node_a, "a-sender", "room:lobby", "cast", "r-2")

  // The broadcast reaches the local sender and the remote observer.
  h.recv(sender_a) |> string.contains("shout") |> should.be_true
  h.recv(observer_b) |> string.contains("shout") |> should.be_true
}

pub fn broadcast_from_excludes_sender_across_runtimes_test() {
  let scope = "app_bcast_from"
  let node_a = start_runtime(scope)
  let node_b = start_runtime(scope)

  let observer_b = join_lobby(node_b, "b-observer", "jr-b")
  let observer_a = join_lobby(node_a, "a-observer", "jr-a2")
  let sender_a = join_lobby(node_a, "a-sender", "jr-a")
  process.sleep(50)

  h.push(node_a, "a-sender", "room:lobby", "cast_others", "r-2")

  // Both observers (local and remote) hear the shout; the sender does not.
  h.recv(observer_a) |> string.contains("shout") |> should.be_true
  h.recv(observer_b) |> string.contains("shout") |> should.be_true
  h.recv_none(sender_a)
}
