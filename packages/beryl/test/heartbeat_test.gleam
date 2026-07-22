//// Heartbeat behavior on the app runtime: replies, staleness eviction at
//// the server-derived check interval (`heartbeat_timeout_ms / 2`), closer
//// invocation on eviction, `Closed(HeartbeatTimeout)` delivery, and
//// `child_spec` config validation.

import app_test_helpers as h
import beryl
import beryl/event.{AcceptJoin, Join, Next}
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gleeunit/should

/// Start an app system that accepts every join and forwards every event to
/// the observer, with the given heartbeat timeout (server checks at half
/// that interval).
fn start_hb_app(
  timeout_ms: Int,
  events: process.Subject(event.Event(Nil)),
) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_heartbeat(interval_ms: 30_000, timeout_ms: timeout_ms),
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

fn send_heartbeat(
  channels: beryl.Sockets,
  socket_id: String,
  ref: String,
) -> Nil {
  h.route(
    channels,
    socket_id,
    "[null,\"" <> ref <> "\",\"phoenix\",\"heartbeat\",{}]",
  )
}

/// Drain all pending frames from a subject.
fn drain(frames: process.Subject(String)) -> Nil {
  case process.receive(frames, 0) {
    Ok(_) -> drain(frames)
    Error(_) -> Nil
  }
}

/// Probe liveness: a heartbeat from a registered socket gets a reply; a
/// heartbeat from an evicted socket does not.
fn socket_is_connected(
  channels: beryl.Sockets,
  socket_id: String,
  frames: process.Subject(String),
) -> Bool {
  drain(frames)
  send_heartbeat(channels, socket_id, "probe")
  case process.receive(frames, 50) {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn heartbeat_reply_is_sent_test() {
  let events = process.new_subject()
  let channels = start_hb_app(60_000, events)
  let frames = h.connect(channels, "hb-reply")

  send_heartbeat(channels, "hb-reply", "hb-1")

  let reply = h.recv(frames)
  string.contains(reply, "phx_reply") |> should.be_true
  string.contains(reply, "\"hb-1\"") |> should.be_true

  beryl.stop(channels)
}

pub fn socket_connected_initializes_heartbeat_timestamp_test() {
  let events = process.new_subject()
  let channels = start_hb_app(200, events)
  let frames = h.connect(channels, "hb-fresh")

  // A freshly connected socket is alive well within its first window.
  socket_is_connected(channels, "hb-fresh", frames) |> should.be_true

  beryl.stop(channels)
}

pub fn heartbeat_timeout_evicts_stale_socket_test() {
  let events = process.new_subject()
  let channels = start_hb_app(100, events)
  let frames = h.connect(channels, "hb-stale")

  // Never heartbeat; wait past the timeout plus a couple of check cycles.
  process.sleep(300)

  socket_is_connected(channels, "hb-stale", frames) |> should.be_false

  beryl.stop(channels)
}

pub fn heartbeat_resets_timeout_test() {
  let events = process.new_subject()
  let channels = start_hb_app(150, events)
  let frames = h.connect(channels, "hb-alive")

  // Keep heartbeating at under half the timeout for two full windows.
  process.sleep(60)
  send_heartbeat(channels, "hb-alive", "hb-1")
  process.sleep(60)
  send_heartbeat(channels, "hb-alive", "hb-2")
  process.sleep(60)
  send_heartbeat(channels, "hb-alive", "hb-3")
  process.sleep(60)

  socket_is_connected(channels, "hb-alive", frames) |> should.be_true

  beryl.stop(channels)
}

pub fn heartbeat_timeout_only_evicts_stale_sockets_test() {
  let events = process.new_subject()
  let channels = start_hb_app(150, events)
  let stale_frames = h.connect(channels, "hb-idle")
  let active_frames = h.connect(channels, "hb-busy")

  process.sleep(80)
  send_heartbeat(channels, "hb-busy", "hb-1")
  process.sleep(80)
  send_heartbeat(channels, "hb-busy", "hb-2")
  process.sleep(80)
  send_heartbeat(channels, "hb-busy", "hb-3")

  socket_is_connected(channels, "hb-idle", stale_frames) |> should.be_false
  socket_is_connected(channels, "hb-busy", active_frames) |> should.be_true

  beryl.stop(channels)
}

pub fn periodic_check_runs_repeatedly_test() {
  let events = process.new_subject()
  let channels = start_hb_app(100, events)

  // Let several check cycles pass before this socket even connects; a
  // one-shot check would miss it.
  process.sleep(150)
  let frames = h.connect(channels, "hb-late")
  socket_is_connected(channels, "hb-late", frames) |> should.be_true

  process.sleep(300)
  socket_is_connected(channels, "hb-late", frames) |> should.be_false

  beryl.stop(channels)
}

pub fn heartbeat_eviction_closes_the_transport_connection_test() {
  let events = process.new_subject()
  let channels = start_hb_app(100, events)
  let _frames = h.connect(channels, "hb-zombie")

  let closed = process.new_subject()
  transport.register_closer(channels, "hb-zombie", fn() {
    process.send(closed, Nil)
  })

  let assert Ok(Nil) = process.receive(closed, 1000)

  beryl.stop(channels)
}

pub fn closed_delivered_with_heartbeat_timeout_reason_test() {
  let events = process.new_subject()
  let channels = start_hb_app(100, events)
  let frames = h.connect(channels, "hb-member")
  h.join(channels, "hb-member", "room:lobby", "j1", "r1")
  let _join_reply = h.recv(frames)

  // Wait for eviction, then find the Closed event among the observed ones.
  wait_for_closed(events)

  beryl.stop(channels)
}

fn wait_for_closed(events: process.Subject(event.Event(Nil))) -> Nil {
  let assert Ok(ev) = process.receive(events, 1000)
  case ev {
    event.Closed("room:lobby", event.HeartbeatTimeout) -> Nil
    _ -> wait_for_closed(events)
  }
}

pub fn eviction_cleans_topic_but_keeps_other_members_test() {
  let events = process.new_subject()
  let channels = start_hb_app(150, events)

  let stale_frames = h.connect(channels, "hb-gone")
  h.join(channels, "hb-gone", "room:shared", "j1", "r1")
  let _ = h.recv(stale_frames)

  let active_frames = h.connect(channels, "hb-here")
  h.join(channels, "hb-here", "room:shared", "j2", "r2")
  let _ = h.recv(active_frames)

  // Keep the active socket alive while the stale one times out.
  process.sleep(80)
  send_heartbeat(channels, "hb-here", "hb-1")
  process.sleep(80)
  send_heartbeat(channels, "hb-here", "hb-2")
  process.sleep(80)
  send_heartbeat(channels, "hb-here", "hb-3")

  socket_is_connected(channels, "hb-gone", stale_frames) |> should.be_false

  // The surviving member still receives topic broadcasts.
  drain(active_frames)
  beryl.broadcast(
    channels,
    "room:shared",
    "ping",
    json.object([#("ok", json.bool(True))]),
  )
  let frame = h.recv(active_frames)
  string.contains(frame, "ping") |> should.be_true

  beryl.stop(channels)
}

// ── start_app heartbeat config validation ────────────────────────────────
//
// The server derives its check interval as `heartbeat_timeout_ms / 2`
// (integer division), so a timeout of 1 would round the check interval down
// to 0 and silently disable eviction. `child_spec` rejects timeouts below 2.

pub fn start_app_rejects_timeout_of_one_test() {
  start_trivial(1)
  |> should.equal(Error(beryl.HeartbeatTimeoutTooLow(2)))
}

pub fn start_app_rejects_zero_timeout_test() {
  start_trivial(0)
  |> should.equal(Error(beryl.HeartbeatTimeoutTooLow(2)))
}

pub fn start_app_rejects_negative_timeout_test() {
  start_trivial(-5)
  |> should.equal(Error(beryl.HeartbeatTimeoutTooLow(2)))
}

pub fn start_app_accepts_timeout_of_two_test() {
  let assert Ok(channels) = start_trivial(2)
  beryl.stop(channels)
}

pub fn start_app_accepts_default_timeout_test() {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: event.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, _ev) { Next(model, []) },
    )
  beryl.stop(channels)
}

fn start_trivial(timeout_ms: Int) -> Result(beryl.Sockets, beryl.ConfigError) {
  h.start_app(
    beryl.config(wire.phoenix_codec())
      |> beryl.with_heartbeat(interval_ms: 30_000, timeout_ms: timeout_ms),
    init: fn(_info: event.ConnectInfo(Nil)) { #(Nil, []) },
    update: fn(model, _ev) { Next(model, []) },
  )
}
