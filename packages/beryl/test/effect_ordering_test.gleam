//// Effect ordering guarantees (ADR 0002 open question 2): effects apply
//// strictly in list order within one actor turn, so list order is wire
//// order; `Push` validity is evaluated against subscription state as of
//// its position in the list; broadcasts ordered before an `AcceptJoin`
//// exclude the joining socket.

import app_test_helpers as h
import beryl
import beryl/event.{
  AcceptJoin, Broadcast, BroadcastFrom, Join, Message, Next, Push,
}
import beryl/wire
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

/// Joins to `room:*` are accepted with effects chosen by topic suffix:
/// - "room:ack-then-push": [AcceptJoin, Push, Push] — ordered pushes
/// - "room:push-first":    [Push, AcceptJoin] — push dropped (not joined yet)
/// - "room:cast-first":    [Broadcast, AcceptJoin] — joiner excluded
fn start_system() -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join("room:ack-then-push" as topic, _payload, ref) ->
            Next(model, [
              AcceptJoin(ref, None),
              Push(topic, "first", json.object([])),
              Push(topic, "second", json.object([])),
            ])
          Join("room:push-first" as topic, _payload, ref) ->
            Next(model, [
              Push(topic, "too_early", json.object([])),
              AcceptJoin(ref, None),
            ])
          Join("room:cast-first" as topic, _payload, ref) ->
            Next(model, [
              Broadcast(topic, "cast", json.object([])),
              AcceptJoin(ref, None),
            ])
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(topic, "shout_others", _payload, _ref) ->
            Next(model, [BroadcastFrom(topic, "shout", json.object([]))])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

pub fn accept_join_ack_precedes_pushes_on_wire_test() {
  let channels = start_system()
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:ack-then-push", "jr-1", "r-1")

  let first = h.recv(frames)
  first |> string.contains("phx_reply") |> should.be_true
  first |> string.contains("\"status\":\"ok\"") |> should.be_true
  let second = h.recv(frames)
  second |> string.contains("first") |> should.be_true
  let third = h.recv(frames)
  third |> string.contains("second") |> should.be_true
}

pub fn push_before_accept_join_is_dropped_test() {
  let channels = start_system()
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:push-first", "jr-1", "r-1")

  // The only frame is the join ack: the push ran while the topic was not
  // yet subscribed and was dropped.
  let reply = h.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  h.recv_none(frames)
}

pub fn broadcast_before_accept_join_excludes_joiner_test() {
  let channels = start_system()

  // s1 is already in the room and sees the broadcast.
  let frames1 = h.connect(channels, "s1")
  h.join(channels, "s1", "room:cast-first", "jr-1", "r-1")
  // s1's own join also broadcasts before its accept; drain its frames.
  let _reply1 = h.recv(frames1)

  let frames2 = h.connect(channels, "s2")
  h.join(channels, "s2", "room:cast-first", "jr-2", "r-2")

  // s1 receives the broadcast triggered by s2's join.
  let cast = h.recv(frames1)
  cast |> string.contains("cast") |> should.be_true
  // s2 receives only its join ack: at broadcast time it was not yet
  // subscribed.
  let reply2 = h.recv(frames2)
  reply2 |> string.contains("phx_reply") |> should.be_true
  h.recv_none(frames2)
}

pub fn broadcast_from_excludes_sender_test() {
  let channels = start_system()
  let frames1 = h.connect(channels, "s1")
  h.join(channels, "s1", "room:x", "jr-1", "r-1")
  let _reply1 = h.recv(frames1)
  let frames2 = h.connect(channels, "s2")
  h.join(channels, "s2", "room:x", "jr-2", "r-2")
  let _reply2 = h.recv(frames2)

  h.push(channels, "s1", "room:x", "shout_others", "r-3")

  // s2 hears the shout; s1 (the sender) does not.
  let shout = h.recv(frames2)
  shout |> string.contains("shout") |> should.be_true
  h.recv_none(frames1)
}
