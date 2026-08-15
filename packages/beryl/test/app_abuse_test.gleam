//// Abuse controls for app-side dispatch: the join-rate limiter rejects
//// excess joins, the message-rate limiter (runtime, post-decode) sheds
//// flooded messages and protocol frames without ever consuming a token for
//// joins, the per-socket topic cap rejects extra joins, and the
//// channel-rate bucket cap bounds the number of distinct topic buckets a
//// socket may allocate (recovering when a topic closes, isolated per socket).
//// These tests drive the runtime directly through `transport.route_decoded`
//// (via the `app_test_helpers` wrappers), the same path any transport uses
//// after decoding a frame; frame-rate edge admission is covered separately
//// in `transport_server_rate_test.gleam`.

import app_test_helpers as h
import beryl
import beryl/socket.{Join, Message}
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleam/int
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn join_ok(
  channels: beryl.Sockets,
  events: process.Subject(socket.Input(Nil)),
  frames: process.Subject(String),
  socket_id: String,
  topic_name: String,
  join_ref: String,
) -> Nil {
  h.join_ok(channels, frames, socket_id, topic_name, join_ref, "r-join")
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  Nil
}

// ── Join rate ───────────────────────────────────────────────────────────────

pub fn join_rate_limit_rejects_excess_joins_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_join_rate(per_second: 1, burst: 1)
  let channels = h.start_observed(config, events)
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
  let channels = h.start_observed(config, events)
  let frames = h.connect(channels, "s1")
  join_ok(channels, events, frames, "s1", "room:a", "jr-1")

  // Burst of 1: the first message is delivered, the second is shed by the
  // runtime's message-rate limiter (post-decode).
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
  let channels = h.start_observed(config, events)
  let frames = h.connect(channels, "s1")

  // The message limiter also guards protocol frames: only one heartbeat in
  // the burst gets a reply.
  h.route(channels, "s1", "[null,\"hb-1\",\"phoenix\",\"heartbeat\",{}]")
  h.route(channels, "s1", "[null,\"hb-2\",\"phoenix\",\"heartbeat\",{}]")
  let reply = h.recv(frames)
  reply |> string.contains("hb-1") |> should.be_true
  h.recv_none(frames)
}

pub fn joins_do_not_consume_message_rate_token_test() {
  // Regression: joins never touch the message-rate bucket. A message-rate
  // burst of exactly 1 stays fully available after two joins, so it still
  // gates on the first post-join message rather than being pre-spent.
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 1, burst: 1)
  let channels = h.start_observed(config, events)
  let frames = h.connect(channels, "s1")
  join_ok(channels, events, frames, "s1", "room:a", "jr-1")
  join_ok(channels, events, frames, "s1", "room:b", "jr-2")

  // The single message token is still available: the first message lands.
  h.push(channels, "s1", "room:a", "msg", "r-1")
  let assert Ok(Message("room:a", "msg", _, _)) = process.receive(events, 500)

  // The second message spends the token the joins never touched.
  h.push(channels, "s1", "room:b", "msg", "r-2")
  process.receive(events, 100) |> should.be_error
}

pub fn invalid_decoded_event_consumes_message_rate_token_test() {
  // Regression: a decoded event with a semantically invalid topic/event
  // still consumes a message-rate token, even though it never reaches the
  // app. With a burst of 1, the invalid envelope spends the only token, so
  // a following valid message is shed too.
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 1, burst: 1)
  let channels = h.start_observed(config, events)
  let frames = h.connect(channels, "s1")
  join_ok(channels, events, frames, "s1", "room:a", "jr-1")

  // A control-character topic on a Message frame is decoded successfully
  // but rejected as an invalid topic before dispatch.
  h.route(
    channels,
    "s1",
    "[null,\"r-bad\",\"room:\\nbad\",\"client_event\",{}]",
  )
  // The valid follow-up message finds the bucket already spent.
  h.push(channels, "s1", "room:a", "msg", "r-good")
  process.receive(events, 200) |> should.be_error
}

pub fn direct_route_decoded_enforces_message_rate_test() {
  // `beryl/transport.route_decoded` is the direct SPI entry a custom
  // transport calls after decoding a frame itself; it goes through the
  // same runtime message-rate enforcement as the `app_test_helpers.route`
  // wrapper used elsewhere in this file (which forwards to it).
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 1, burst: 1)
  let channels = h.start_observed(config, events)
  let frames = h.connect(channels, "s1")
  join_ok(channels, events, frames, "s1", "room:a", "jr-1")

  let assert Ok(first) =
    codec.decode_text(transport.active_codec(channels))(
      "[null,\"r-1\",\"room:a\",\"msg\",{}]",
    )
  transport.route_decoded(channels, "s1", first)
  let assert Ok(Message("room:a", "msg", _, _)) = process.receive(events, 500)

  let assert Ok(second) =
    codec.decode_text(transport.active_codec(channels))(
      "[null,\"r-2\",\"room:a\",\"msg\",{}]",
    )
  transport.route_decoded(channels, "s1", second)
  process.receive(events, 100) |> should.be_error
}

// ── Per-socket topic cap ─────────────────────────────────────────────────────

pub fn topic_cap_rejects_excess_join_test() {
  let events = process.new_subject()
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_joined_topics_per_socket(1)
  let channels = h.start_observed(config, events)
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
  let channels = h.start_observed(capped_config(), events)
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
  let channels = h.start_observed(capped_config(), events)
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
  let assert Ok(socket.Closed("room:a", _)) = process.receive(events, 500)
  let _close_frame = h.recv(frames)

  h.push(channels, "s1", "room:c", "m", "r-c")
  let assert Ok(Message("room:c", _, _, _)) = process.receive(events, 500)
}

pub fn channel_bucket_cap_is_isolated_per_socket_test() {
  let events = process.new_subject()
  let channels = h.start_observed(capped_config(), events)
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

pub fn unjoined_events_do_not_consume_channel_bucket_cap_test() {
  // Regression: messages on never-joined topics must not allocate a rate-limit
  // bucket slot, so a socket that is flooded before joining a legitimate topic
  // still has its full cap available.
  let events = process.new_subject()
  let channels =
    h.start_observed(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_channel_rate(per_second: 100, burst: 100)
        |> beryl.with_channel_rate_max_keys_per_socket(1),
      events,
    )
  let frames = h.connect(channels, "s-sec")

  // Flood 50 messages on never-joined topics; none should create a bucket.
  flood_unjoined(channels, "s-sec", 50)
  process.sleep(50)

  // The single cap slot is still available for a legitimately joined topic.
  join_ok(channels, events, frames, "s-sec", "room:real", "jr-real")
  h.push(channels, "s-sec", "room:real", "client_event", "r-real")
  let assert Ok(Message("room:real", _, _, _)) = process.receive(events, 500)
}

fn flood_unjoined(channels: beryl.Sockets, socket_id: String, n: Int) -> Nil {
  case n <= 0 {
    True -> Nil
    False -> {
      // Use null ref so the runtime does not enqueue an error reply frame;
      // the flood should only probe whether bucket slots are consumed.
      h.route(
        channels,
        socket_id,
        "[null,null,\"room:unjoined-"
          <> int.to_string(n)
          <> "\",\"client_event\",{}]",
      )
      flood_unjoined(channels, socket_id, n - 1)
    }
  }
}
