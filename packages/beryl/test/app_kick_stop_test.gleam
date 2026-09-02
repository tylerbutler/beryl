//// `KickTopic` and `Stop` follow-ups: kicks deliver `Closed(Shutdown)`
//// and terminal frames after the current effects list; kick chains from
//// `Closed` handling terminate; `Stop` tears down the whole socket and
//// invokes the transport closer.

import app_test_helper
import beryl
import beryl/socket.{AcceptJoin, Closed, Join, KickTopic, Message, Next, Stop}
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit/should

/// Joins accepted for all topics. "kick_b" kicks room:b; a Closed for
/// room:b kicks room:c (a kick chain); "stop" stops the socket.
fn start_system(events: process.Subject(socket.Input(Nil))) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        process.send(events, ev)
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(_topic, "kick_b", _payload, _ref) ->
            Next(model, [KickTopic("room:b")])
          Message(_topic, "stop", _payload, _ref) -> Stop(socket.Normal)
          Closed("room:b", socket.Shutdown) ->
            Next(model, [KickTopic("room:c")])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

fn join_rooms(
  channels: beryl.Sockets,
  events: process.Subject(socket.Input(Nil)),
  frames: process.Subject(String),
  socket_id: String,
  topics: List(String),
) -> Nil {
  case topics {
    [] -> Nil
    [topic_name, ..rest] -> {
      app_test_helper.join_ok(
        channels,
        frames,
        socket_id,
        topic_name,
        "jr-" <> topic_name,
        "r-1",
      )
      let assert Ok(Join(_, _, _)) = process.receive(events, 500)
      join_rooms(channels, events, frames, socket_id, rest)
    }
  }
}

pub fn kick_closes_topic_and_leaves_others_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = app_test_helper.connect(channels, "s1")
  join_rooms(channels, events, frames, "s1", ["room:a", "room:b"])

  app_test_helper.push(channels, "s1", "room:a", "kick_b", "r-2")

  let assert Ok(Message(_, "kick_b", _, _)) = process.receive(events, 500)
  // room:b is kicked, but the Closed for room:b chains a kick of room:c —
  // which is not joined, so the chain ends there.
  let assert Ok(Closed("room:b", socket.Shutdown)) =
    process.receive(events, 500)
  let close_frame = app_test_helper.recv(frames)
  close_frame |> string.contains("phx_close") |> should.be_true
  close_frame |> string.contains("room:b") |> should.be_true

  // room:a is untouched and still receives messages.
  app_test_helper.push(channels, "s1", "room:a", "noop", "r-3")
  let assert Ok(Message("room:a", "noop", _, _)) = process.receive(events, 500)
  Nil
}

pub fn kick_chain_from_closed_terminates_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = app_test_helper.connect(channels, "s1")
  join_rooms(channels, events, frames, "s1", ["room:a", "room:b", "room:c"])

  app_test_helper.push(channels, "s1", "room:a", "kick_b", "r-2")

  let assert Ok(Message(_, "kick_b", _, _)) = process.receive(events, 500)
  // Kick of room:b delivers Closed, whose handling kicks room:c in turn.
  let assert Ok(Closed("room:b", socket.Shutdown)) =
    process.receive(events, 500)
  let assert Ok(Closed("room:c", socket.Shutdown)) =
    process.receive(events, 500)
  let close_b = app_test_helper.recv(frames)
  close_b |> string.contains("room:b") |> should.be_true
  let close_c = app_test_helper.recv(frames)
  close_c |> string.contains("room:c") |> should.be_true

  // room:a survives the chain.
  app_test_helper.push(channels, "s1", "room:a", "noop", "r-3")
  let assert Ok(Message("room:a", "noop", _, _)) = process.receive(events, 500)
  Nil
}

pub fn stop_tears_down_socket_and_calls_closer_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let closed = process.new_subject()
  let frames =
    app_test_helper.connect_with_close(channels, "s1", fn() {
      process.send(closed, Nil)
    })
  join_rooms(channels, events, frames, "s1", ["room:a", "room:b"])

  app_test_helper.push(channels, "s1", "room:a", "stop", "r-2")

  let assert Ok(Message(_, "stop", _, _)) = process.receive(events, 500)
  // Every joined topic gets Closed (sorted order) and a terminal frame.
  let assert Ok(Closed("room:a", socket.Normal)) = process.receive(events, 500)
  let assert Ok(Closed("room:b", socket.Normal)) = process.receive(events, 500)
  let close_a = app_test_helper.recv(frames)
  close_a |> string.contains("phx_close") |> should.be_true
  let close_b = app_test_helper.recv(frames)
  close_b |> string.contains("phx_close") |> should.be_true
  // The transport closer is invoked.
  let assert Ok(Nil) = process.receive(closed, 500)

  // The socket is gone: further messages are ignored.
  app_test_helper.push(channels, "s1", "room:a", "noop", "r-3")
  process.receive(events, 100) |> should.be_error
}
