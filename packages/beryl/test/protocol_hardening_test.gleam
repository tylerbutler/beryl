//// Protocol hardening tests on the app runtime: reserved names and
//// rate-limit coverage for protocol frames.

import app_test_helper
import beryl
import beryl/socket.{AcceptJoin, Join, Message, Next}
import beryl/wire
import gleam/erlang/process
import gleam/option
import gleam/string
import gleeunit/should

/// Accepts every join and forwards every event to the observer.
fn start_observed(
  events: process.Subject(socket.Input(Nil)),
  config: beryl.Config,
) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      config,
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        process.send(events, ev)
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, option.None)])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

fn count_messages(subject: process.Subject(String), count: Int) -> Int {
  case process.receive(subject, 50) {
    Ok(_) -> count_messages(subject, count + 1)
    Error(_) -> count
  }
}

pub fn heartbeat_flood_is_message_rate_limited_test() -> Nil {
  let events = process.new_subject()
  let channels =
    start_observed(
      events,
      beryl.config(wire.phoenix_codec())
        |> beryl.with_message_rate(per_second: 1, burst: 2),
    )

  let frames = app_test_helper.connect(channels, "socket-1")
  send_heartbeats(channels, "socket-1", 10)

  // Only the burst allowance produces replies; the flood is shed.
  let replies = count_messages(frames, 0)
  { replies <= 2 } |> should.be_true
  { replies >= 1 } |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

fn send_heartbeats(
  channels: beryl.Sockets,
  socket_id: String,
  remaining: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      app_test_helper.route(
        channels,
        socket_id,
        "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]",
      )
      send_heartbeats(channels, socket_id, remaining - 1)
    }
  }
}

pub fn join_to_reserved_beryl_topic_is_rejected_test() -> Nil {
  let events = process.new_subject()
  let channels = start_observed(events, beryl.config(wire.phoenix_codec()))

  let frames = app_test_helper.connect(channels, "socket-1")
  app_test_helper.route(
    channels,
    "socket-1",
    "[null,\"ref-1\",\"beryl:presence:sync\",\"phx_join\",{}]",
  )

  // Rejected with an error reply even though the app accepts every join.
  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn client_sent_reserved_phx_events_never_reach_the_app_test() -> Nil {
  let events = process.new_subject()
  let channels = start_observed(events, beryl.config(wire.phoenix_codec()))

  let frames = app_test_helper.connect(channels, "socket-1")
  app_test_helper.join(channels, "socket-1", "room:lobby", "j1", "j1")
  let _join_reply = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // A forged protocol event must be dropped before the app's update.
  app_test_helper.route(
    channels,
    "socket-1",
    "[\"j1\",\"ref-2\",\"room:lobby\",\"phx_reply\",{}]",
  )
  process.receive(events, 100) |> should.be_error

  // Ordinary events still flow.
  app_test_helper.route(
    channels,
    "socket-1",
    "[\"j1\",\"ref-3\",\"room:lobby\",\"shout\",{}]",
  )
  let assert Ok(Message(_, "shout", _, _)) = process.receive(events, 500)

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}
