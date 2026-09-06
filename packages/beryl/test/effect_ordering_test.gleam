//// Effect ordering guarantees (ADR 0002 open question 2): effects apply
//// strictly in list order within one actor turn, so list order is wire
//// order; `Push` validity is evaluated against subscription state as of
//// its position in the list; broadcasts ordered before an `AcceptJoin`
//// exclude the joining socket.

import app_test_helper
import beryl
import beryl/socket.{
  AcceptJoin, Binary, Broadcast, BroadcastFrom, Closed, Info, Join, Message,
  Next, Push,
}
import beryl/wire
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit/should

/// Joins to `room:*` are accepted with effects chosen by topic suffix:
/// - "room:ack-then-push": [AcceptJoin, Push, Push] — ordered pushes
/// - "room:push-first":    [Push, AcceptJoin] — push dropped (not joined yet)
/// - "room:cast-first":    [Broadcast, AcceptJoin] — joiner excluded
fn start_system() -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, event) {
        case event {
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
          Message(_, _, _, _) | Binary(_, _) | Closed(_, _) | Info(_) ->
            Next(model, [])
        }
      },
    )
  channels
}

pub fn accept_join_ack_precedes_pushes_on_wire_test() -> Nil {
  let channels = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:ack-then-push", "jr-1", "r-1")

  let first = app_test_helper.recv(frames)
  first |> string.contains("phx_reply") |> should.be_true
  first |> string.contains("\"status\":\"ok\"") |> should.be_true
  let second = app_test_helper.recv(frames)
  second |> string.contains("first") |> should.be_true
  let third = app_test_helper.recv(frames)
  third |> string.contains("second") |> should.be_true
}

pub fn push_before_accept_join_is_dropped_test() -> Nil {
  let channels = start_system()
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:push-first", "jr-1", "r-1")

  // The only frame is the join ack: the push ran while the topic was not
  // yet subscribed and was dropped.
  let reply = app_test_helper.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  app_test_helper.recv_none(frames)
}

pub fn broadcast_before_accept_join_excludes_joiner_test() -> Nil {
  let channels = start_system()

  // s1 is already in the room and sees the broadcast.
  let frames1 = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:cast-first", "jr-1", "r-1")
  // s1's own join also broadcasts before its accept; drain its frames.
  let _reply1 = app_test_helper.recv(frames1)

  let frames2 = app_test_helper.connect(channels, "s2")
  app_test_helper.join(channels, "s2", "room:cast-first", "jr-2", "r-2")

  // s1 receives the broadcast triggered by s2's join.
  let cast = app_test_helper.recv(frames1)
  cast |> string.contains("cast") |> should.be_true
  // s2 receives only its join ack: at broadcast time it was not yet
  // subscribed.
  let reply2 = app_test_helper.recv(frames2)
  reply2 |> string.contains("phx_reply") |> should.be_true
  app_test_helper.recv_none(frames2)
}

pub fn broadcast_from_excludes_sender_test() -> Nil {
  let channels = start_system()
  let frames1 = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:x", "jr-1", "r-1")
  let _reply1 = app_test_helper.recv(frames1)
  let frames2 = app_test_helper.connect(channels, "s2")
  app_test_helper.join(channels, "s2", "room:x", "jr-2", "r-2")
  let _reply2 = app_test_helper.recv(frames2)

  app_test_helper.push(channels, "s1", "room:x", "shout_others", "r-3")

  // s2 hears the shout; s1 (the sender) does not.
  let shout = app_test_helper.recv(frames2)
  shout |> string.contains("shout") |> should.be_true
  app_test_helper.recv_none(frames1)
}
