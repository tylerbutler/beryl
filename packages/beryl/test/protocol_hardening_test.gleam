//// Protocol hardening tests on the app runtime: reserved names and
//// rate-limit coverage for protocol frames.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Message, Next}
import beryl/wire
import gleam/erlang/process
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

/// Accepts every join and forwards every event to the observer.
fn start_observed(
  events: process.Subject(event.Input(Nil)),
  config: beryl.Config,
) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(config, init: fn(_info) { #(Nil, []) }, update: fn(model, ev) {
      process.send(events, ev)
      case ev {
        Join(_, _, ref) -> Next(model, [AcceptJoin(ref, option.None)])
        _ -> Next(model, [])
      }
    })
  channels
}

fn count_messages(subject: process.Subject(String), count: Int) -> Int {
  case process.receive(subject, 50) {
    Ok(_) -> count_messages(subject, count + 1)
    Error(_) -> count
  }
}

pub fn heartbeat_flood_is_message_rate_limited_test() {
  let events = process.new_subject()
  let channels =
    start_observed(
      events,
      beryl.config(wire.phoenix_codec())
        |> beryl.with_message_rate(per_second: 1, burst: 2),
    )

  let frames = h.connect(channels, "socket-1")
  send_heartbeats(channels, "socket-1", 10)

  // Only the burst allowance produces replies; the flood is shed.
  let replies = count_messages(frames, 0)
  { replies <= 2 } |> should.be_true
  { replies >= 1 } |> should.be_true

  beryl.stop(channels)
}

fn send_heartbeats(
  channels: beryl.Sockets,
  socket_id: String,
  remaining: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      h.route(channels, socket_id, "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]")
      send_heartbeats(channels, socket_id, remaining - 1)
    }
  }
}

pub fn join_to_reserved_beryl_topic_is_rejected_test() {
  let events = process.new_subject()
  let channels = start_observed(events, beryl.config(wire.phoenix_codec()))

  let frames = h.connect(channels, "socket-1")
  h.route(
    channels,
    "socket-1",
    "[null,\"ref-1\",\"beryl:presence:sync\",\"phx_join\",{}]",
  )

  // Rejected with an error reply even though the app accepts every join.
  let reply = h.recv(frames)
  reply |> string.contains("\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true

  beryl.stop(channels)
}

pub fn client_sent_reserved_phx_events_never_reach_the_app_test() {
  let events = process.new_subject()
  let channels = start_observed(events, beryl.config(wire.phoenix_codec()))

  let frames = h.connect(channels, "socket-1")
  h.join(channels, "socket-1", "room:lobby", "j1", "j1")
  let _join_reply = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // A forged protocol event must be dropped before the app's update.
  h.route(
    channels,
    "socket-1",
    "[\"j1\",\"ref-2\",\"room:lobby\",\"phx_reply\",{}]",
  )
  process.receive(events, 100) |> should.be_error

  // Ordinary events still flow.
  h.route(
    channels,
    "socket-1",
    "[\"j1\",\"ref-3\",\"room:lobby\",\"shout\",{}]",
  )
  let assert Ok(Message(_, "shout", _, _)) = process.receive(events, 500)

  beryl.stop(channels)
}
