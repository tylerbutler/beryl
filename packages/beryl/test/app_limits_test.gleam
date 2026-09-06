//// Topic/event length and control-character limits for app-side dispatch.
////
//// These enforce the wire-level protections that run before an event is
//// dispatched to the app's `update`: joins to control-character or
//// over-byte-limit topics are rejected with an `invalid_topic` reply, and
//// events whose names exceed the byte limit are dropped silently.

import app_test_helper
import beryl
import beryl/socket.{Join, Message}
import beryl/wire
import gleam/erlang/process
import gleam/string
import gleeunit/should

pub fn join_with_control_character_topic_gets_error_reply_test() -> Nil {
  let events = process.new_subject()
  let channels =
    app_test_helper.start_observed(beryl.config(wire.phoenix_codec()), events)
  let frames = app_test_helper.connect(channels, "s1")

  // The topic contains a newline (JSON escape `\n`) — rejected before it
  // can reach the app's update.
  app_test_helper.route(
    channels,
    "s1",
    "[null,\"r-1\",\"room:\\nlobby\",\"phx_join\",{}]",
  )

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
  process.receive(events, 100) |> should.be_error
}

pub fn join_with_too_long_topic_gets_error_reply_test() -> Nil {
  let events = process.new_subject()
  let channels =
    app_test_helper.start_observed(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_topic_length(max_length: 64),
      events,
    )
  let frames = app_test_helper.connect(channels, "s1")

  let long_topic = "room:" <> string.repeat("a", 300)
  app_test_helper.join(channels, "s1", long_topic, "jr-1", "r-1")

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
  process.receive(events, 100) |> should.be_error
}

pub fn join_topic_over_byte_limit_but_under_grapheme_limit_gets_error_reply_test() -> Nil {
  let events = process.new_subject()
  let channels =
    app_test_helper.start_observed(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_topic_length(max_length: 64),
      events,
    )
  let frames = app_test_helper.connect(channels, "s1")

  // 37 graphemes but 101 bytes: "room:" (5 bytes) + 32 x "€" (3 bytes each).
  // max_topic_length is a byte limit, so this must be rejected.
  let multibyte_topic = "room:" <> string.repeat("€", 32)
  app_test_helper.join(channels, "s1", multibyte_topic, "jr-1", "r-1")

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
  process.receive(events, 100) |> should.be_error
}

pub fn event_over_byte_limit_but_under_grapheme_limit_is_dropped_test() -> Nil {
  let events = process.new_subject()
  let channels =
    app_test_helper.start_observed(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_event_length(max_length: 16),
      events,
    )
  let frames = app_test_helper.connect(channels, "s1")

  app_test_helper.join(channels, "s1", "room:lobby", "jr-1", "r-1")
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  let _join_reply = app_test_helper.recv(frames)

  // 10 graphemes but 30 bytes: max_event_length is a byte limit, so this
  // event must be dropped before reaching the app.
  let oversized_event = string.repeat("€", 10)
  app_test_helper.push(channels, "s1", "room:lobby", oversized_event, "r-2")
  // Sentinel: events are processed in order, so if the oversized event were
  // dispatched it would arrive before "ping".
  app_test_helper.push(channels, "s1", "room:lobby", "ping", "r-3")

  let assert Ok(Message("room:lobby", "ping", _, _)) =
    process.receive(events, 500)
  Nil
}
