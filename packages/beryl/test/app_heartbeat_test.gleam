//// Heartbeat eviction for app-side dispatch: a socket that stops sending
//// heartbeats is evicted after the configured timeout — every joined topic
//// receives `Closed(HeartbeatTimeout)`, a terminal frame is sent, and the
//// transport connection is force-closed via its registered closer. Sockets
//// that keep heartbeating survive while stale peers are evicted.

import app_test_helpers as h
import beryl
import beryl/socket.{AcceptJoin, Closed, Join, Next}
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn start_system(events: process.Subject(socket.Input(Nil))) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_heartbeat(interval_ms: 20, timeout_ms: 40),
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

fn connect_with_closer(
  channels: beryl.Sockets,
  socket_id: String,
  closed: process.Subject(Nil),
) -> process.Subject(String) {
  h.connect_with_close(channels, socket_id, fn() { process.send(closed, Nil) })
}

pub fn heartbeat_timeout_evicts_stale_socket_and_runs_closer_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let closed = process.new_subject()
  let frames = connect_with_closer(channels, "s1", closed)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // No heartbeats arrive: the periodic check evicts the socket. Every joined
  // topic is closed with HeartbeatTimeout and a terminal frame is sent.
  let assert Ok(Closed("room:a", socket.HeartbeatTimeout)) =
    process.receive(events, 2000)
  let close_frame = h.recv(frames)
  close_frame |> string.contains("phx_close") |> should.be_true

  // The transport connection is force-closed through its registered closer.
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
}

pub fn evicted_socket_is_removed_and_ignores_further_input_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let closed = process.new_subject()
  let frames = connect_with_closer(channels, "s1", closed)
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  let assert Ok(Closed("room:a", socket.HeartbeatTimeout)) =
    process.receive(events, 2000)
  let _close_frame = h.recv(frames)

  // The socket is gone: a later join is ignored and no frame is produced.
  h.join(channels, "s1", "room:b", "jr-2", "r-2")
  h.recv_none(frames)
  process.receive(events, 100) |> should.be_error
}

pub fn active_socket_survives_while_stale_peer_is_evicted_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let stale_closed = process.new_subject()
  let active_closed = process.new_subject()

  let stale = connect_with_closer(channels, "stale", stale_closed)
  h.join(channels, "stale", "room:a", "jr-1", "r-1")
  let _stale_reply = h.recv(stale)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  let active = connect_with_closer(channels, "active", active_closed)
  h.join(channels, "active", "room:a", "jr-2", "r-2")
  let _active_reply = h.recv(active)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // Keep the active socket alive across several timeout windows by sending
  // heartbeats faster than the 40ms timeout; the stale socket sends none.
  send_heartbeats(channels, active, "active", 8)

  // The stale peer was evicted (closer ran); the active one was not.
  process.receive(stale_closed, 2000) |> should.equal(Ok(Nil))
  process.receive(active_closed, 0) |> should.be_error
  process.is_alive(runtime_pid(channels)) |> should.be_true

  // The active socket still serves: it can join another topic.
  h.join(channels, "active", "room:b", "jr-3", "r-3")
  h.recv(active) |> string.contains("\"status\":\"ok\"") |> should.be_true
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
      h.route(channels, socket_id, "[null,\"hb\",\"phoenix\",\"heartbeat\",{}]")
      let _hb_reply = h.recv(frames)
      process.sleep(15)
      send_heartbeats(channels, frames, socket_id, remaining - 1)
    }
  }
}

fn runtime_pid(channels: beryl.Sockets) -> process.Pid {
  let assert Ok(pid) = beryl.app_runtime_pid(channels)
  pid
}
