//// Abuse controls for app-side dispatch: the join-rate limiter rejects
//// excess joins, the message-rate limiter sheds flooded messages and
//// protocol frames, the per-socket topic cap rejects extra joins, and the
//// channel-rate bucket cap bounds the number of distinct topic buckets a
//// socket may allocate (recovering when a topic closes, isolated per socket).

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

fn start_system(
  config: beryl.Config,
  events: process.Subject(event.Event(Nil)),
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

fn join_ok(
  channels: beryl.Sockets,
  events: process.Subject(event.Event(Nil)),
  frames: process.Subject(String),
  socket_id: String,
  topic_name: String,
  join_ref: String,
) -> Nil {
  h.join(channels, socket_id, topic_name, join_ref, "r-join")
  h.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  Nil
}

// ── Join rate ───────────────────────────────────────────────────────────────

pub fn join_rate_limit_rejects_excess_joins_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_join_rate(per_second: 1, burst: 1)
  let channels = start_system(config, events)
  let frames = h.connect(channels, "s1")

  // Burst of 1: the first join is accepted, the second is rejected before
  // reaching the app with a rate_limited error reply.
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  h.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  h.join(channels, "s1", "room:b", "jr-2", "r-2")
  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("rate_limited") |> should.be_true
  process.receive(events, 100) |> should.be_error
}

// ── Message / protocol flood ─────────────────────────────────────────────────

pub fn message_rate_limit_sheds_flood_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 1, burst: 1)
  let channels = start_system(config, events)
  let frames = h.connect(channels, "s1")
  join_ok(channels, events, frames, "s1", "room:a", "jr-1")

  // Burst of 1: the first message is delivered, the second is shed at the
  // transport edge.
  h.push(channels, "s1", "room:a", "msg", "r-2")
  h.push(channels, "s1", "room:a", "msg", "r-3")
  let assert Ok(Message("room:a", "msg", _, _)) = process.receive(events, 500)
  process.receive(events, 100) |> should.be_error
}

pub fn heartbeat_flood_is_message_rate_limited_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 1, burst: 1)
  let channels = start_system(config, events)
  let frames = h.connect(channels, "s1")

  // The message limiter also guards protocol frames: only one heartbeat in
  // the burst gets a reply.
  h.route(channels, "s1", "[null,\"hb-1\",\"phoenix\",\"heartbeat\",{}]")
  h.route(channels, "s1", "[null,\"hb-2\",\"phoenix\",\"heartbeat\",{}]")
  let reply = h.recv(frames)
  reply |> string.contains("hb-1") |> should.be_true
  h.recv_none(frames)
}

// ── Per-socket topic cap ─────────────────────────────────────────────────────

pub fn topic_cap_rejects_excess_join_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_joined_topics_per_socket(1)
  let channels = start_system(config, events)
  let frames = h.connect(channels, "s1")
  join_ok(channels, events, frames, "s1", "room:a", "jr-1")

  // The second distinct topic exceeds the cap and is rejected.
  h.join(channels, "s1", "room:b", "jr-2", "r-2")
  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("too_many_topics") |> should.be_true
  process.receive(events, 100) |> should.be_error
}

// ── Channel-rate bucket cap ──────────────────────────────────────────────────

fn capped_config() -> beryl.Config {
  beryl.config(wire.phoenix_codec())
  |> beryl.with_channel_rate(per_second: 100, burst: 100)
  |> beryl.with_channel_rate_max_keys_per_socket(2)
}

pub fn channel_bucket_cap_bounds_distinct_topics_test() {
  let events = process.new_subject()
  let channels = start_system(capped_config(), events)
  let frames = h.connect(channels, "s1")
  join_ok(channels, events, frames, "s1", "room:a", "jr-a")
  join_ok(channels, events, frames, "s1", "room:b", "jr-b")
  join_ok(channels, events, frames, "s1", "room:c", "jr-c")

  // A message on each of the first two topics allocates a bucket; the third
  // distinct topic exceeds the bucket cap and its message is dropped.
  h.push(channels, "s1", "room:a", "m", "r-a")
  let assert Ok(Message("room:a", _, _, _)) = process.receive(events, 500)
  h.push(channels, "s1", "room:b", "m", "r-b")
  let assert Ok(Message("room:b", _, _, _)) = process.receive(events, 500)
  h.push(channels, "s1", "room:c", "m", "r-c")
  process.receive(events, 200) |> should.be_error
}

pub fn channel_bucket_cap_recovers_after_leave_test() {
  let events = process.new_subject()
  let channels = start_system(capped_config(), events)
  let frames = h.connect(channels, "s1")
  join_ok(channels, events, frames, "s1", "room:a", "jr-a")
  join_ok(channels, events, frames, "s1", "room:b", "jr-b")
  join_ok(channels, events, frames, "s1", "room:c", "jr-c")
  h.push(channels, "s1", "room:a", "m", "r-a")
  let assert Ok(Message("room:a", _, _, _)) = process.receive(events, 500)
  h.push(channels, "s1", "room:b", "m", "r-b")
  let assert Ok(Message("room:b", _, _, _)) = process.receive(events, 500)

  // Leaving room:a frees its bucket, so room:c can now allocate one.
  h.route(channels, "s1", "[\"jr-a\",\"r-leave\",\"room:a\",\"phx_leave\",{}]")
  let _leave_reply = h.recv(frames)
  let assert Ok(event.Closed("room:a", _)) = process.receive(events, 500)
  let _close_frame = h.recv(frames)

  h.push(channels, "s1", "room:c", "m", "r-c")
  let assert Ok(Message("room:c", _, _, _)) = process.receive(events, 500)
}

pub fn channel_bucket_cap_is_isolated_per_socket_test() {
  let events = process.new_subject()
  let channels = start_system(capped_config(), events)
  let frames1 = h.connect(channels, "s1")
  let frames2 = h.connect(channels, "s2")
  join_ok(channels, events, frames1, "s1", "room:a", "jr-a")
  join_ok(channels, events, frames1, "s1", "room:b", "jr-b")
  join_ok(channels, events, frames2, "s2", "room:x", "jr-x")
  join_ok(channels, events, frames2, "s2", "room:y", "jr-y")

  // s1 fills its cap; s2's independent cap is unaffected.
  h.push(channels, "s1", "room:a", "m", "r-a")
  let assert Ok(Message("room:a", _, _, _)) = process.receive(events, 500)
  h.push(channels, "s1", "room:b", "m", "r-b")
  let assert Ok(Message("room:b", _, _, _)) = process.receive(events, 500)
  h.push(channels, "s2", "room:x", "m", "r-x")
  let assert Ok(Message("room:x", _, _, _)) = process.receive(events, 500)
  h.push(channels, "s2", "room:y", "m", "r-y")
  let assert Ok(Message("room:y", _, _, _)) = process.receive(events, 500)
}
