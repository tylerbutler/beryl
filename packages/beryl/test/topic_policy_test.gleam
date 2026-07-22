//// Per-topic-pattern abuse config (`beryl.with_topic_rate`): the first
//// matching pattern wins, unmatched topics fall back to the global
//// channel rate, and no limits means unlimited.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Message, Next}
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_system(
  config: beryl.Config,
  events: process.Subject(event.Event(Nil)),
) -> beryl.Channels {
  let assert Ok(channels) =
    h.start_app(
      config,
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

fn drain_join(
  channels: beryl.Channels,
  events: process.Subject(event.Event(Nil)),
  frames: process.Subject(String),
  socket_id: String,
  topic_name: String,
) -> Nil {
  h.join(channels, socket_id, topic_name, "jr-1", "r-1")
  let _reply = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  Nil
}

pub fn topic_rate_limits_matching_pattern_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 1, burst: 1)
  let channels = start_system(config, events)
  let frames = h.connect(channels, "s1")
  drain_join(channels, events, frames, "s1", "room:a")

  // Burst of 1: the first message is delivered, the second is shed.
  h.push(channels, "s1", "room:a", "msg", "r-2")
  h.push(channels, "s1", "room:a", "msg", "r-3")

  let assert Ok(Message("room:a", "msg", _, _)) = process.receive(events, 500)
  process.receive(events, 100) |> should.be_error
}

pub fn unmatched_topic_falls_back_to_global_channel_rate_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 1, burst: 1)
    |> beryl.with_channel_rate(per_second: 2, burst: 2)
  let channels = start_system(config, events)
  let frames = h.connect(channels, "s1")
  drain_join(channels, events, frames, "s1", "other:a")

  // "other:a" matches no topic pattern, so the global burst of 2 applies:
  // two delivered, the third shed.
  h.push(channels, "s1", "other:a", "msg", "r-2")
  h.push(channels, "s1", "other:a", "msg", "r-3")
  h.push(channels, "s1", "other:a", "msg", "r-4")

  let assert Ok(Message("other:a", _, _, _)) = process.receive(events, 500)
  let assert Ok(Message("other:a", _, _, _)) = process.receive(events, 500)
  process.receive(events, 100) |> should.be_error
}

pub fn no_matching_limits_means_unlimited_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 1, burst: 1)
  let channels = start_system(config, events)
  let frames = h.connect(channels, "s1")
  drain_join(channels, events, frames, "s1", "other:a")

  h.push(channels, "s1", "other:a", "msg", "r-2")
  h.push(channels, "s1", "other:a", "msg", "r-3")
  h.push(channels, "s1", "other:a", "msg", "r-4")

  let assert Ok(Message(_, _, _, _)) = process.receive(events, 500)
  let assert Ok(Message(_, _, _, _)) = process.receive(events, 500)
  let assert Ok(Message(_, _, _, _)) = process.receive(events, 500)
}
