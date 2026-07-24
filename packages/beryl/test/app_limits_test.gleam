//// Topic/event length and control-character limits for app-side dispatch.
////
//// These enforce the wire-level protections that run before an event is
//// dispatched to the app's `update`: joins to control-character or
//// over-byte-limit topics are rejected with an `invalid_topic` reply, and
//// events whose names exceed the byte limit are dropped silently.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Message, Next}
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_with(
  config: beryl.Config,
  events: process.Subject(event.Input(Nil)),
) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(config, init: fn(_info) { #(Nil, []) }, update: fn(model, ev) {
      process.send(events, ev)
      case ev {
        Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
        _ -> Next(model, [])
      }
    })
  channels
}

pub fn join_with_control_character_topic_gets_error_reply_test() {
  let events = process.new_subject()
  let channels = start_with(beryl.config(wire.phoenix_codec()), events)
  let frames = h.connect(channels, "s1")

  // The topic contains a newline (JSON escape `\n`) — rejected before it
  // can reach the app's update.
  h.route(channels, "s1", "[null,\"r-1\",\"room:\\nlobby\",\"phx_join\",{}]")

  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
  process.receive(events, 100) |> should.be_error
}

pub fn join_with_too_long_topic_gets_error_reply_test() {
  let events = process.new_subject()
  let channels =
    start_with(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_topic_length(max_length: 64),
      events,
    )
  let frames = h.connect(channels, "s1")

  let long_topic = "room:" <> string.repeat("a", 300)
  h.join(channels, "s1", long_topic, "jr-1", "r-1")

  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
  process.receive(events, 100) |> should.be_error
}

pub fn join_topic_over_byte_limit_but_under_grapheme_limit_gets_error_reply_test() {
  let events = process.new_subject()
  let channels =
    start_with(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_topic_length(max_length: 64),
      events,
    )
  let frames = h.connect(channels, "s1")

  // 37 graphemes but 101 bytes: "room:" (5 bytes) + 32 x "€" (3 bytes each).
  // max_topic_length is a byte limit, so this must be rejected.
  let multibyte_topic = "room:" <> string.repeat("€", 32)
  h.join(channels, "s1", multibyte_topic, "jr-1", "r-1")

  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
  process.receive(events, 100) |> should.be_error
}

pub fn event_over_byte_limit_but_under_grapheme_limit_is_dropped_test() {
  let events = process.new_subject()
  let channels =
    start_with(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_event_length(max_length: 16),
      events,
    )
  let frames = h.connect(channels, "s1")

  h.join(channels, "s1", "room:lobby", "jr-1", "r-1")
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  let _join_reply = h.recv(frames)

  // 10 graphemes but 30 bytes: max_event_length is a byte limit, so this
  // event must be dropped before reaching the app.
  let oversized_event = string.repeat("€", 10)
  h.push(channels, "s1", "room:lobby", oversized_event, "r-2")
  // Sentinel: events are processed in order, so if the oversized event were
  // dispatched it would arrive before "ping".
  h.push(channels, "s1", "room:lobby", "ping", "r-3")

  let assert Ok(Message("room:lobby", "ping", _, _)) =
    process.receive(events, 500)
}
