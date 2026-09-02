//// Heartbeat eviction for app-side dispatch: a socket that stops sending
//// heartbeats is evicted after the configured timeout — every joined topic
//// receives `Closed(HeartbeatTimeout)`, a terminal frame is sent, and the
//// transport connection is force-closed via its registered closer. Sockets
//// that keep heartbeating survive while stale peers are evicted.

import app_test_helper
import beryl
import beryl/socket.{Closed, Join}
import beryl/wire
import gleam/erlang/process
import gleam/string
import gleeunit/should

fn start_system(events: process.Subject(socket.Input(Nil))) -> beryl.Sockets {
  app_test_helper.start_observed(
    beryl.config(wire.phoenix_codec())
      |> beryl.with_heartbeat(timeout_ms: 40),
    events,
  )
}

fn start_message_limited_system(
  events: process.Subject(socket.Input(Nil)),
) -> beryl.Sockets {
  app_test_helper.start_observed(
    beryl.config(wire.phoenix_codec())
      |> beryl.with_heartbeat(timeout_ms: 40)
      |> beryl.with_message_rate(per_second: 1, burst: 1),
    events,
  )
}

fn connect_with_closer(
  channels: beryl.Sockets,
  socket_id: String,
  closed: process.Subject(Nil),
) -> process.Subject(String) {
  app_test_helper.connect_with_close(channels, socket_id, fn() {
    process.send(closed, Nil)
  })
}

pub fn heartbeat_timeout_evicts_stale_socket_and_runs_closer_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let closed = process.new_subject()
  let frames = connect_with_closer(channels, "s1", closed)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // No heartbeats arrive: the periodic check evicts the socket. Every joined
  // topic is closed with HeartbeatTimeout and a terminal frame is sent.
  let assert Ok(Closed("room:a", socket.HeartbeatTimeout)) =
    process.receive(events, 2000)
  let close_frame = app_test_helper.recv(frames)
  close_frame |> string.contains("phx_close") |> should.be_true

  // The transport connection is force-closed through its registered closer.
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
}

pub fn evicted_socket_is_removed_and_ignores_further_input_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let closed = process.new_subject()
  let frames = connect_with_closer(channels, "s1", closed)
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  let assert Ok(Closed("room:a", socket.HeartbeatTimeout)) =
    process.receive(events, 2000)
  let _close_frame = app_test_helper.recv(frames)

  // The socket is gone: a later join is ignored and no frame is produced.
  app_test_helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  app_test_helper.recv_none(frames)
  process.receive(events, 100) |> should.be_error
}

pub fn active_socket_survives_while_stale_peer_is_evicted_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let stale_closed = process.new_subject()
  let active_closed = process.new_subject()

  let stale = connect_with_closer(channels, "stale", stale_closed)
  app_test_helper.join(channels, "stale", "room:a", "jr-1", "r-1")
  let _stale_reply = app_test_helper.recv(stale)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  let active = connect_with_closer(channels, "active", active_closed)
  app_test_helper.join(channels, "active", "room:a", "jr-2", "r-2")
  let _active_reply = app_test_helper.recv(active)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // Keep the active socket alive across several timeout windows by sending
  // heartbeats faster than the 40ms timeout; the stale socket sends none.
  send_heartbeats(channels, active, "active", 8)

  // The stale peer was evicted (closer ran); the active one was not.
  process.receive(stale_closed, 2000) |> should.equal(Ok(Nil))
  process.receive(active_closed, 0) |> should.be_error
  process.is_alive(app_test_helper.runtime_pid(channels)) |> should.be_true

  // The active socket still serves: it can join another topic.
  app_test_helper.join(channels, "active", "room:b", "jr-3", "r-3")
  app_test_helper.recv(active)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
}

pub fn message_rate_limited_heartbeats_lead_to_eviction_test() -> Nil {
  let events = process.new_subject()
  let channels = start_message_limited_system(events)
  let closed = process.new_subject()
  let frames = connect_with_closer(channels, "flooding", closed)

  // Spend the only burst token on a heartbeat, then keep sending heartbeats
  // faster than the bucket can refill. The shed heartbeats must not refresh
  // last_heartbeat, so the normal timeout path closes the connection.
  app_test_helper.route(
    channels,
    "flooding",
    "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]",
  )
  let _heartbeat_reply = app_test_helper.recv(frames)
  flood_heartbeats(channels, "flooding", 20)

  process.receive(closed, 1000) |> should.equal(Ok(Nil))
}

fn flood_heartbeats(
  channels: beryl.Sockets,
  socket_id: String,
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      app_test_helper.route(
        channels,
        socket_id,
        "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]",
      )
      process.sleep(5)
      flood_heartbeats(channels, socket_id, remaining - 1)
    }
  }
}

fn send_heartbeats(
  channels: beryl.Sockets,
  frames: process.Subject(String),
  socket_id: String,
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      app_test_helper.route(
        channels,
        socket_id,
        "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]",
      )
      let _hb_reply = app_test_helper.recv(frames)
      process.sleep(15)
      send_heartbeats(channels, frames, socket_id, remaining - 1)
    }
  }
}
