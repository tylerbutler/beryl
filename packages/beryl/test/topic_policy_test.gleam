//// Per-topic-pattern abuse config (`beryl.with_topic_rate`): the first
//// matching pattern wins, unmatched topics fall back to the global
//// channel rate, and no limits means unlimited.

import app_test_helper
import beryl
import beryl/socket.{Join, Message}
import beryl/wire
import gleam/erlang/process
import gleeunit/should

fn drain_join(
  channels: beryl.Sockets,
  events: process.Subject(socket.Input(Nil)),
  frames: process.Subject(String),
  socket_id: String,
  topic_name: String,
) -> Nil {
  app_test_helper.join_ok(
    channels,
    frames,
    socket_id,
    topic_name,
    "jr-1",
    "r-1",
  )
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  Nil
}

pub fn topic_rate_limits_matching_pattern_test() -> Nil {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 1, burst: 1)
  let channels = app_test_helper.start_observed(config, events)
  let frames = app_test_helper.connect(channels, "s1")
  drain_join(channels, events, frames, "s1", "room:a")

  // Burst of 1: the first message is delivered, the second is shed.
  app_test_helper.push(channels, "s1", "room:a", "message", "r-2")
  app_test_helper.push(channels, "s1", "room:a", "message", "r-3")

  let assert Ok(Message("room:a", "message", _, _)) =
    process.receive(events, 500)
  process.receive(events, 100) |> should.be_error
}

pub fn unmatched_topic_falls_back_to_global_channel_rate_test() -> Nil {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 1, burst: 1)
    |> beryl.with_channel_rate(per_second: 2, burst: 2)
  let channels = app_test_helper.start_observed(config, events)
  let frames = app_test_helper.connect(channels, "s1")
  drain_join(channels, events, frames, "s1", "other:a")

  // "other:a" matches no topic pattern, so the global burst of 2 applies:
  // two delivered, the third shed.
  app_test_helper.push(channels, "s1", "other:a", "message", "r-2")
  app_test_helper.push(channels, "s1", "other:a", "message", "r-3")
  app_test_helper.push(channels, "s1", "other:a", "message", "r-4")

  let assert Ok(Message("other:a", _, _, _)) = process.receive(events, 500)
  let assert Ok(Message("other:a", _, _, _)) = process.receive(events, 500)
  process.receive(events, 100) |> should.be_error
}

pub fn no_matching_limits_means_unlimited_test() -> Nil {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 1, burst: 1)
  let channels = app_test_helper.start_observed(config, events)
  let frames = app_test_helper.connect(channels, "s1")
  drain_join(channels, events, frames, "s1", "other:a")

  app_test_helper.push(channels, "s1", "other:a", "message", "r-2")
  app_test_helper.push(channels, "s1", "other:a", "message", "r-3")
  app_test_helper.push(channels, "s1", "other:a", "message", "r-4")

  let assert Ok(Message(_, _, _, _)) = process.receive(events, 500)
  let assert Ok(Message(_, _, _, _)) = process.receive(events, 500)
  let assert Ok(Message(_, _, _, _)) = process.receive(events, 500)
  Nil
}

fn non_positive_topic_rate_disables_global_limit(rate: Int) -> Nil {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_channel_rate(per_second: 1, burst: 1)
    |> beryl.with_topic_rate(pattern: "room:*", per_second: rate, burst: 1)
  let channels = app_test_helper.start_observed(config, events)
  let frames = app_test_helper.connect(channels, "s1")
  drain_join(channels, events, frames, "s1", "room:a")

  app_test_helper.push(channels, "s1", "room:a", "message", "r-2")
  app_test_helper.push(channels, "s1", "room:a", "message", "r-3")
  app_test_helper.push(channels, "s1", "room:a", "message", "r-4")

  let assert Ok(Message("room:a", _, _, _)) = process.receive(events, 500)
  let assert Ok(Message("room:a", _, _, _)) = process.receive(events, 500)
  let assert Ok(Message("room:a", _, _, _)) = process.receive(events, 500)
  Nil
}

pub fn zero_topic_rate_disables_override_without_allocating_bucket_test() -> Nil {
  non_positive_topic_rate_disables_global_limit(0)
}

pub fn negative_topic_rate_disables_override_without_allocating_bucket_test() -> Nil {
  non_positive_topic_rate_disables_global_limit(-1)
}
