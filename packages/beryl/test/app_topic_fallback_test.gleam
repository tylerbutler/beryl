//// Topicless-event fallback for app-side dispatch. A codec that opts into
//// topicless events (`codec.with_topicless_events`) resolves an empty-topic
//// event to the socket's single joined topic; the plain Phoenix codec never
//// guesses and drops empty-topic events, and a topicless event with no join
//// (or more than one join) is dropped.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Message, Next}
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_system(
  the_codec: codec.Codec,
  events: process.Subject(event.Event(Nil)),
) -> beryl.Channels {
  let assert Ok(channels) =
    beryl.start_app(
      beryl.config(the_codec),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        process.send(events, ev)
        case ev {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

fn join_room(
  channels: beryl.Channels,
  events: process.Subject(event.Event(Nil)),
  frames: process.Subject(String),
  topic_name: String,
) -> Nil {
  h.join(channels, "s1", topic_name, "jr-1", "r-1")
  let _reply = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  Nil
}

pub fn topicless_event_routes_to_single_join_test() {
  let events = process.new_subject()
  let channels =
    start_system(wire.phoenix_codec() |> codec.with_topicless_events(), events)
  let frames = h.connect(channels, "s1")
  join_room(channels, events, frames, "room:lobby")

  // Empty topic falls back to the one joined topic.
  h.route(channels, "s1", "[null,null,\"\",\"submitOp\",{}]")
  let assert Ok(Message("room:lobby", "submitOp", _, _)) =
    process.receive(events, 500)
}

pub fn phoenix_codec_drops_topicless_events_test() {
  let events = process.new_subject()
  let channels = start_system(wire.phoenix_codec(), events)
  let frames = h.connect(channels, "s1")
  join_room(channels, events, frames, "room:lobby")

  // The plain Phoenix codec never guesses, even with exactly one join.
  h.route(channels, "s1", "[null,null,\"\",\"submitOp\",{}]")
  process.receive(events, 200) |> should.be_error
}

pub fn topicless_event_without_join_is_dropped_test() {
  let events = process.new_subject()
  let channels =
    start_system(wire.phoenix_codec() |> codec.with_topicless_events(), events)
  let _frames = h.connect(channels, "s1")

  // No join to fall back to: the event is dropped.
  h.route(channels, "s1", "[null,null,\"\",\"submitOp\",{}]")
  process.receive(events, 200) |> should.be_error
}
