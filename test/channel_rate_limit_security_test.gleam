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

pub fn unjoined_events_do_not_create_channel_buckets_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 1000, burst: 1000))
  let assert Ok(coord) =
    coordinator.start_with_config(
      coordinator.CoordinatorConfig(
        ..coordinator.config(wire.phoenix_codec()),
        channel_limiter: option.Some(limiter),
        channel_limiter_max_keys_per_socket: 1000,
      ),
    )

  process.send(
    coord,
    coordinator.SocketConnected(
      "socket-131",
      fn(_) { Ok(Nil) },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  send_unjoined_events(coord, 50)
  process.sleep(50)

  rate_limit.bucket_count(limiter) |> should.equal(0)
  rate_limit.stop(limiter)
}

pub fn joined_topics_cannot_exceed_channel_bucket_cap_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 1000, burst: 1000))
  let assert Ok(coord) =
    coordinator.start_with_config(
      coordinator.CoordinatorConfig(
        ..coordinator.config(wire.phoenix_codec()),
        channel_limiter: option.Some(limiter),
        channel_limiter_max_keys_per_socket: 2,
      ),
    )
  let sent = process.new_subject()
  let assert Ok(_) = register_test_channel(coord, sent)

  connect(coord, sent, "socket-cap")
  join(coord, "socket-cap", "room:one")
  join(coord, "socket-cap", "room:two")
  join(coord, "socket-cap", "room:three")

  event(coord, "socket-cap", "room:one", "ref-one")
  event(coord, "socket-cap", "room:two", "ref-two")
  event(coord, "socket-cap", "room:three", "ref-three")
  process.sleep(50)

  rate_limit.bucket_count(limiter) |> should.equal(2)
  rate_limit.stop(limiter)
}

pub fn heartbeat_eviction_removes_channel_buckets_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 1000, burst: 1000))
  let assert Ok(coord) =
    coordinator.start_with_config(
      coordinator.CoordinatorConfig(
        ..coordinator.config(wire.phoenix_codec()),
        heartbeat_timeout_ms: 20,
        channel_limiter: option.Some(limiter),
        channel_limiter_max_keys_per_socket: 1000,
      ),
    )
  let sent = process.new_subject()
  let assert Ok(_) = register_test_channel(coord, sent)

  connect(coord, sent, "socket-heartbeat")
  join(coord, "socket-heartbeat", "room:one")
  event(coord, "socket-heartbeat", "room:one", "ref-one")
  process.sleep(20)
  rate_limit.bucket_count(limiter) |> should.equal(1)

  process.sleep(30)
  process.send(coord, coordinator.CheckHeartbeats)
  process.sleep(20)

  rate_limit.bucket_count(limiter) |> should.equal(0)
  rate_limit.stop(limiter)
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
    "[\"join-"
      <> topic
      <> "\",\""
      <> ref
      <> "\",\""
      <> topic
      <> "\",\"client_event\",{}]",
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
