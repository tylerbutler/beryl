//// Behavioural tests for per-channel rate-limit bucket accounting: buckets
//// are only created for joined topics, are capped per socket, and are
//// released when the channel or socket goes away.

import beryl/coordinator
import beryl/rate_limit
import beryl/topic
import beryl/wire
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_capped_coordinator(
  max_keys: Int,
) -> process.Subject(coordinator.Message) {
  let assert Ok(coord) =
    coordinator.start_with_config(
      coordinator.CoordinatorConfig(
        ..coordinator.config(wire.phoenix_codec()),
        channel_limits: option.Some(rate_limit.config(
          per_second: 1000,
          burst: 1000,
        )),
        channel_limiter_max_keys_per_socket: max_keys,
      ),
    )
  coord
}

/// Wait for a "handled" marker from the channel, skipping wire frames (join
/// replies etc.) that share the same capture subject.
fn expect_handled(sent: process.Subject(String)) -> Nil {
  case process.receive(sent, 500) {
    Ok("handled") -> Nil
    Ok(_frame) -> expect_handled(sent)
    Error(Nil) -> should.fail()
  }
}

/// Assert that no "handled" marker arrives, skipping wire frames.
fn expect_dropped(sent: process.Subject(String)) -> Nil {
  case process.receive(sent, 100) {
    Ok("handled") -> should.fail()
    Ok(_frame) -> expect_dropped(sent)
    Error(Nil) -> Nil
  }
}

/// Discard everything currently queued on the capture subject.
fn drain_replies(subject: process.Subject(String)) -> Nil {
  case process.receive(subject, 0) {
    Ok(_) -> drain_replies(subject)
    Error(Nil) -> Nil
  }
}

pub fn unjoined_events_do_not_consume_channel_bucket_cap_test() {
  let coord = start_capped_coordinator(1)
  let sent = process.new_subject()
  let assert Ok(_) = register_test_channel(coord, sent)

  connect(coord, sent, "socket-131")

  // A flood of events for never-joined topics must not create buckets and
  // must not consume the per-socket cap.
  send_unjoined_events(coord, 50)
  process.sleep(50)
  drain_replies(sent)

  // The single cap slot is still available for a legitimately joined topic.
  join(coord, "socket-131", "room:one")
  event(coord, "socket-131", "room:one", "ref-one")
  expect_handled(sent)
}

pub fn joined_topics_cannot_exceed_channel_bucket_cap_test() {
  let coord = start_capped_coordinator(2)
  let sent = process.new_subject()
  let assert Ok(_) = register_test_channel(coord, sent)

  connect(coord, sent, "socket-cap")
  join(coord, "socket-cap", "room:one")
  join(coord, "socket-cap", "room:two")
  join(coord, "socket-cap", "room:three")

  event(coord, "socket-cap", "room:one", "ref-one")
  expect_handled(sent)
  event(coord, "socket-cap", "room:two", "ref-two")
  expect_handled(sent)

  // The third topic would need a third bucket, over the cap: dropped.
  event(coord, "socket-cap", "room:three", "ref-three")
  expect_dropped(sent)
}

pub fn heartbeat_eviction_releases_channel_buckets_test() {
  let assert Ok(coord) =
    coordinator.start_with_config(
      coordinator.CoordinatorConfig(
        ..coordinator.config(wire.phoenix_codec()),
        heartbeat_timeout_ms: 20,
        channel_limits: option.Some(rate_limit.config(
          per_second: 1000,
          burst: 1000,
        )),
        channel_limiter_max_keys_per_socket: 1,
      ),
    )
  let sent = process.new_subject()
  let assert Ok(_) = register_test_channel(coord, sent)

  connect(coord, sent, "socket-heartbeat")
  join(coord, "socket-heartbeat", "room:one")
  event(coord, "socket-heartbeat", "room:one", "ref-one")
  expect_handled(sent)

  // Let the socket go stale and evict it.
  process.sleep(30)
  process.send(coord, coordinator.CheckHeartbeats)
  process.sleep(20)

  // A reconnect under the same socket id starts with a free cap: if the old
  // bucket had leaked, this event would exceed max_keys_per_socket = 1.
  connect(coord, sent, "socket-heartbeat")
  join(coord, "socket-heartbeat", "room:two")
  drain_replies(sent)
  event(coord, "socket-heartbeat", "room:two", "ref-two")
  expect_handled(sent)
}

pub fn leave_removes_channel_bucket_so_cap_recovers_test() {
  let coord = start_capped_coordinator(2)
  let sent = process.new_subject()
  let assert Ok(_) = register_test_channel(coord, sent)

  connect(coord, sent, "socket-leave")
  join(coord, "socket-leave", "room:one")
  join(coord, "socket-leave", "room:two")
  event(coord, "socket-leave", "room:one", "ref-one")
  expect_handled(sent)
  event(coord, "socket-leave", "room:two", "ref-two")
  expect_handled(sent)

  // Leaving frees room:one's bucket, so a third topic fits under the cap.
  leave(coord, "socket-leave", "room:one", "leave-one")
  join(coord, "socket-leave", "room:three")
  process.sleep(20)
  drain_replies(sent)
  event(coord, "socket-leave", "room:three", "ref-three")
  expect_handled(sent)
}

fn send_unjoined_events(
  coord: process.Subject(coordinator.Message),
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let topic = "room:unjoined-" <> int.to_string(remaining)
      coordinator.route_message(
        coord,
        "socket-131",
        "[null,\"ref-"
          <> int.to_string(remaining)
          <> "\",\""
          <> topic
          <> "\",\"event\",{}]",
      )
      send_unjoined_events(coord, remaining - 1)
    }
  }
}

fn connect(
  coord: process.Subject(coordinator.Message),
  sent: process.Subject(String),
  socket_id: String,
) -> Nil {
  process.send(
    coord,
    coordinator.SocketConnected(
      socket_id,
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )
  process.sleep(10)
}

fn join(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
  topic: String,
) -> Nil {
  coordinator.route_message(
    coord,
    socket_id,
    "[null,\"join-" <> topic <> "\",\"" <> topic <> "\",\"phx_join\",{}]",
  )
}

fn event(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
  topic: String,
  ref: String,
) -> Nil {
  coordinator.route_message(
    coord,
    socket_id,
    "[null,\"" <> ref <> "\",\"" <> topic <> "\",\"client_event\",{}]",
  )
}

fn leave(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
  topic: String,
  ref: String,
) -> Nil {
  coordinator.route_message(
    coord,
    socket_id,
    "[null,\"" <> ref <> "\",\"" <> topic <> "\",\"phx_leave\",{}]",
  )
}

fn register_test_channel(
  coord: process.Subject(coordinator.Message),
  sent: process.Subject(String),
) -> Result(Int, coordinator.RegisterError) {
  let reply = process.new_subject()
  process.send(
    coord,
    coordinator.RegisterChannel(
      "room:*",
      coordinator.ChannelHandler(
        id: 0,
        pattern: topic.Wildcard("room:"),
        join: fn(_topic, _payload, ctx) {
          coordinator.JoinOkErased(option.Some(json.object([])), ctx.assigns)
        },
        handle_in: fn(_event, _payload, ctx) {
          process.send(sent, "handled")
          coordinator.NoReplyErased(ctx.assigns)
        },
        handle_binary: fn(_data, ctx) { coordinator.NoReplyErased(ctx.assigns) },
        terminate: fn(_, _) { Nil },
      ),
      reply,
    ),
  )
  case process.receive(reply, 500) {
    Ok(result) -> result
    Error(Nil) -> Error(coordinator.InvalidPattern("timeout"))
  }
}
