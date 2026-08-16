//// Behavioural tests for per-channel rate-limit bucket accounting on the
//// app runtime: buckets are only created for joined topics, are capped per
//// socket, and are released when the topic or socket goes away.

import app_test_helpers as h
import beryl
import beryl/socket.{AcceptJoin, Join, Message, Next}
import beryl/wire
import gleam/erlang/process
import gleam/int
import gleam/option
import gleeunit/should

/// Start an app that accepts every join and forwards events to the
/// observer, with a generous channel rate but a small bucket cap.
fn start_capped_app(
  max_keys: Int,
  events: process.Subject(socket.Input(Nil)),
) -> beryl.Sockets {
  start_capped_app_with(max_keys, events, beryl.config(wire.phoenix_codec()))
}

fn start_capped_app_with(
  max_keys: Int,
  events: process.Subject(socket.Input(Nil)),
  base: beryl.Config,
) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
      base
        |> beryl.with_channel_rate(per_second: 1000, burst: 1000)
        |> beryl.with_channel_rate_max_keys_per_socket(max_keys: max_keys),
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

/// Wait for a `Message` event on the given topic, skipping other events.
fn expect_handled(
  events: process.Subject(socket.Input(Nil)),
  topic: String,
) -> Nil {
  case process.receive(events, 500) {
    Ok(Message(t, _, _, _)) if t == topic -> Nil
    Ok(_other) -> expect_handled(events, topic)
    Error(Nil) -> should.fail()
  }
}

/// Assert that no `Message` event for the topic arrives.
fn expect_dropped(
  events: process.Subject(socket.Input(Nil)),
  topic: String,
) -> Nil {
  case process.receive(events, 100) {
    Ok(Message(t, _, _, _)) if t == topic -> should.fail()
    Ok(_other) -> expect_dropped(events, topic)
    Error(Nil) -> Nil
  }
}

/// Discard everything currently queued on the observer.
fn drain_events(events: process.Subject(socket.Input(Nil))) -> Nil {
  case process.receive(events, 0) {
    Ok(_) -> drain_events(events)
    Error(Nil) -> Nil
  }
}

fn event_frame(
  channels: beryl.Sockets,
  socket_id: String,
  topic: String,
  ref: String,
) -> Nil {
  h.route(
    channels,
    socket_id,
    "[null,\"" <> ref <> "\",\"" <> topic <> "\",\"client_event\",{}]",
  )
}

fn leave(
  channels: beryl.Sockets,
  socket_id: String,
  topic: String,
  ref: String,
) -> Nil {
  h.route(
    channels,
    socket_id,
    "[\"join-"
      <> topic
      <> "\",\""
      <> ref
      <> "\",\""
      <> topic
      <> "\",\"phx_leave\",{}]",
  )
}

fn join(channels: beryl.Sockets, socket_id: String, topic: String) -> Nil {
  h.join(channels, socket_id, topic, "join-" <> topic, "join-" <> topic)
}

pub fn unjoined_events_do_not_consume_channel_bucket_cap_test() {
  let events = process.new_subject()
  let channels = start_capped_app(1, events)

  let _frames = h.connect(channels, "socket-131")

  // A flood of events for never-joined topics must not create buckets and
  // must not consume the per-socket cap.
  send_unjoined_events(channels, 50)
  process.sleep(50)
  drain_events(events)

  // The single cap slot is still available for a legitimately joined topic.
  join(channels, "socket-131", "room:one")
  event_frame(channels, "socket-131", "room:one", "ref-one")
  expect_handled(events, "room:one")

  beryl.stop(channels)
}

pub fn joined_topics_cannot_exceed_channel_bucket_cap_test() {
  let events = process.new_subject()
  let channels = start_capped_app(2, events)

  let _frames = h.connect(channels, "socket-cap")
  join(channels, "socket-cap", "room:one")
  join(channels, "socket-cap", "room:two")
  join(channels, "socket-cap", "room:three")

  event_frame(channels, "socket-cap", "room:one", "ref-one")
  expect_handled(events, "room:one")
  event_frame(channels, "socket-cap", "room:two", "ref-two")
  expect_handled(events, "room:two")

  // The third topic would need a third bucket, over the cap: dropped.
  event_frame(channels, "socket-cap", "room:three", "ref-three")
  expect_dropped(events, "room:three")

  beryl.stop(channels)
}

pub fn channel_bucket_cap_is_isolated_per_socket_test() {
  let events = process.new_subject()
  let channels = start_capped_app(1, events)

  let _frames_one = h.connect(channels, "socket-one")
  let _frames_two = h.connect(channels, "socket-two")
  join(channels, "socket-one", "room:one")
  join(channels, "socket-two", "room:two")
  drain_events(events)

  event_frame(channels, "socket-one", "room:one", "ref-one")
  expect_handled(events, "room:one")
  event_frame(channels, "socket-two", "room:two", "ref-two")
  expect_handled(events, "room:two")

  beryl.stop(channels)
}

pub fn heartbeat_eviction_releases_channel_buckets_test() {
  let events = process.new_subject()
  let channels =
    start_capped_app_with(
      1,
      events,
      beryl.config(wire.phoenix_codec())
        |> beryl.with_heartbeat(timeout_ms: 40),
    )

  let _frames = h.connect(channels, "socket-heartbeat")
  join(channels, "socket-heartbeat", "room:one")
  event_frame(channels, "socket-heartbeat", "room:one", "ref-one")
  expect_handled(events, "room:one")

  // Let the socket go stale and get evicted by the periodic check.
  process.sleep(120)

  // A reconnect under the same socket id starts with a free cap: if the old
  // bucket had leaked, this event would exceed max_keys_per_socket = 1.
  let _frames = h.connect(channels, "socket-heartbeat")
  join(channels, "socket-heartbeat", "room:two")
  drain_events(events)
  event_frame(channels, "socket-heartbeat", "room:two", "ref-two")
  expect_handled(events, "room:two")

  beryl.stop(channels)
}

pub fn leave_removes_channel_bucket_so_cap_recovers_test() {
  let events = process.new_subject()
  let channels = start_capped_app(2, events)

  let _frames = h.connect(channels, "socket-leave")
  join(channels, "socket-leave", "room:one")
  join(channels, "socket-leave", "room:two")
  event_frame(channels, "socket-leave", "room:one", "ref-one")
  expect_handled(events, "room:one")
  event_frame(channels, "socket-leave", "room:two", "ref-two")
  expect_handled(events, "room:two")

  // Leaving frees room:one's bucket, so a third topic fits under the cap.
  leave(channels, "socket-leave", "room:one", "leave-one")
  join(channels, "socket-leave", "room:three")
  process.sleep(20)
  drain_events(events)
  event_frame(channels, "socket-leave", "room:three", "ref-three")
  expect_handled(events, "room:three")

  beryl.stop(channels)
}

fn send_unjoined_events(channels: beryl.Sockets, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let topic = "room:unjoined-" <> int.to_string(remaining)
      h.route(
        channels,
        "socket-131",
        "[null,\"ref-"
          <> int.to_string(remaining)
          <> "\",\""
          <> topic
          <> "\",\"event\",{}]",
      )
      send_unjoined_events(channels, remaining - 1)
    }
  }
}
