//// Protocol hardening tests: reserved names and rate-limit coverage for
//// protocol frames.

import beryl/coordinator
import beryl/rate_limit
import beryl/topic
import beryl/wire
import gleam/dynamic
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn connect(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  let send = fn(message: String) -> Result(Nil, Nil) {
    process.send(sent, message)
    Ok(Nil)
  }
  process.send(
    coord,
    coordinator.SocketConnected(
      socket_id,
      send,
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  process.sleep(10)
  sent
}

fn register_notifying_channel(
  coord: process.Subject(coordinator.Message),
  handled: process.Subject(String),
) -> Nil {
  let handler =
    coordinator.ChannelHandler(
      id: 0,
      pattern: topic.parse_pattern("*"),
      join: fn(_topic, _payload, _ctx) {
        coordinator.JoinOkErased(reply: None, assigns: dynamic.nil())
      },
      handle_in: fn(event, _payload, ctx) {
        process.send(handled, event)
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      handle_binary: fn(_data, ctx) {
        coordinator.NoReplyErased(assigns: ctx.assigns)
      },
      terminate: fn(_reason, _ctx) { Nil },
    )
  let reply = process.new_subject()
  process.send(coord, coordinator.RegisterChannel("*", handler, reply))
  let assert Ok(Ok(_)) = process.receive(reply, 500)
  Nil
}

fn count_messages(subject: process.Subject(String), count: Int) -> Int {
  case process.receive(subject, 50) {
    Ok(_) -> count_messages(subject, count + 1)
    Error(_) -> count
  }
}

pub fn heartbeat_flood_is_message_rate_limited_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 1, burst: 2))
  let assert Ok(coord) =
    coordinator.start_with_config(
      coordinator.CoordinatorConfig(
        ..coordinator.config(wire.phoenix_codec()),
        message_limiter: Some(limiter),
      ),
    )

  let sent = connect(coord, "socket-1")
  send_heartbeats(coord, "socket-1", 10)

  // Only the burst allowance produces replies; the flood is shed.
  let replies = count_messages(sent, 0)
  { replies <= 2 } |> should.be_true
  { replies >= 1 } |> should.be_true
  rate_limit.stop(limiter)
}

fn send_heartbeats(
  coord: process.Subject(coordinator.Message),
  socket_id: String,
  remaining: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      coordinator.route_message(
        coord,
        socket_id,
        "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]",
      )
      send_heartbeats(coord, socket_id, remaining - 1)
    }
  }
}

pub fn join_to_reserved_beryl_topic_is_rejected_test() {
  let assert Ok(coord) = coordinator.start(wire.phoenix_codec())
  let handled = process.new_subject()
  register_notifying_channel(coord, handled)

  let sent = connect(coord, "socket-1")
  coordinator.route_message(
    coord,
    "socket-1",
    "[null,\"ref-1\",\"beryl:presence:sync\",\"phx_join\",{}]",
  )

  // Rejected with an error reply even though a catch-all handler matches.
  let assert Ok(reply) = process.receive(sent, 500)
  reply |> string.contains("\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
}

pub fn client_sent_reserved_phx_events_never_reach_handlers_test() {
  let assert Ok(coord) = coordinator.start(wire.phoenix_codec())
  let handled = process.new_subject()
  register_notifying_channel(coord, handled)

  let sent = connect(coord, "socket-1")
  coordinator.route_message(
    coord,
    "socket-1",
    "[null,\"j1\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_join_reply) = process.receive(sent, 500)

  // A forged protocol event must be dropped before the channel handler.
  coordinator.route_message(
    coord,
    "socket-1",
    "[\"j1\",\"ref-2\",\"room:lobby\",\"phx_reply\",{}]",
  )
  process.receive(handled, 100) |> should.be_error

  // Ordinary events still flow.
  coordinator.route_message(
    coord,
    "socket-1",
    "[\"j1\",\"ref-3\",\"room:lobby\",\"shout\",{}]",
  )
  let assert Ok("shout") = process.receive(handled, 500)
}
