//// Topicless-event fallback for app-side dispatch. A codec that opts into
//// topicless events (`codec.with_topicless_events`) resolves an empty-topic
//// event to the socket's single joined topic; the plain Phoenix codec never
//// guesses and drops empty-topic events, and a topicless event with no join
//// (or more than one join) is dropped.

import app_test_helper
import beryl
import beryl/socket.{Join, Message}
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleeunit/should

fn join_room(
  channels: beryl.Sockets,
  events: process.Subject(socket.Input(Nil)),
  frames: process.Subject(String),
  topic_name: String,
) -> Nil {
  app_test_helper.join_ok(channels, frames, "s1", topic_name, "jr-1", "r-1")
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  Nil
}

pub fn topicless_event_routes_to_single_join_test() -> Nil {
  let events = process.new_subject()
  let channels =
    app_test_helper.start_observed(
      beryl.config(wire.phoenix_codec() |> codec.with_topicless_events()),
      events,
    )
  let frames = app_test_helper.connect(channels, "s1")
  join_room(channels, events, frames, "room:lobby")

  // Empty topic falls back to the one joined topic.
  app_test_helper.route(channels, "s1", "[null,null,\"\",\"submitOp\",{}]")
  let assert Ok(Message("room:lobby", "submitOp", _, _)) =
    process.receive(events, 500)
  Nil
}

pub fn phoenix_codec_drops_topicless_events_test() -> Nil {
  let events = process.new_subject()
  let channels =
    app_test_helper.start_observed(beryl.config(wire.phoenix_codec()), events)
  let frames = app_test_helper.connect(channels, "s1")
  join_room(channels, events, frames, "room:lobby")

  // The plain Phoenix codec never guesses, even with exactly one join.
  app_test_helper.route(channels, "s1", "[null,null,\"\",\"submitOp\",{}]")
  process.receive(events, 200) |> should.be_error
}

pub fn topicless_event_without_join_is_dropped_test() -> Nil {
  let events = process.new_subject()
  let channels =
    app_test_helper.start_observed(
      beryl.config(wire.phoenix_codec() |> codec.with_topicless_events()),
      events,
    )
  let _frames = app_test_helper.connect(channels, "s1")

  // No join to fall back to: the event is dropped.
  app_test_helper.route(channels, "s1", "[null,null,\"\",\"submitOp\",{}]")
  process.receive(events, 200) |> should.be_error
}
