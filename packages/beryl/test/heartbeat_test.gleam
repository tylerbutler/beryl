//// Heartbeat behavior on the app runtime: replies, staleness eviction at
//// the server-derived check interval (`heartbeat_timeout_ms / 2`), closer
//// invocation on eviction, `Closed(HeartbeatTimeout)` delivery, and
//// `child_spec` config validation.

import app_test_helper
import beryl
import beryl/socket.{AcceptJoin, Join, Next}
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gleeunit/should
import test_helper

/// Start an app system that accepts every join and forwards every event to
/// the observer, with the given heartbeat timeout (server checks at half
/// that interval).
fn start_hb_app(
  timeout_ms: Int,
  events: process.Subject(socket.Input(Nil)),
) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_heartbeat(timeout_ms: timeout_ms),
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
  app_test_helper.route(
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
  case process.receive(frames, 500) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn keep_alive_until_evicted(
  channels: beryl.Sockets,
  socket_id: String,
  frames: process.Subject(String),
  evicted: process.Subject(Nil),
) -> Nil {
  test_helper.wait_until(
    fn() {
      case process.receive(evicted, 0) {
        Ok(Nil) -> True
        Error(Nil) -> {
          send_heartbeat(channels, socket_id, "keep-alive")
          let _reply = app_test_helper.recv(frames)
          False
        }
      }
    },
    2000,
    25,
  )
}

pub fn heartbeat_reply_is_sent_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(60_000, events)
  let frames = app_test_helper.connect(channels, "hb-reply")

  send_heartbeat(channels, "hb-reply", "hb-1")

  let reply = app_test_helper.recv(frames)
  string.contains(reply, "phx_reply") |> should.be_true
  string.contains(reply, "\"hb-1\"") |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn socket_connected_initializes_heartbeat_timestamp_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(200, events)
  let frames = app_test_helper.connect(channels, "hb-fresh")

  // A freshly connected socket is alive well within its first window.
  socket_is_connected(channels, "hb-fresh", frames) |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn heartbeat_timeout_evicts_stale_socket_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(100, events)
  let frames = app_test_helper.connect(channels, "hb-stale")

  // Never heartbeat; wait past the timeout plus a couple of check cycles.
  process.sleep(300)

  socket_is_connected(channels, "hb-stale", frames) |> should.be_false

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn heartbeat_resets_timeout_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(500, events)
  let evicted = process.new_subject()
  let _stale_frames =
    app_test_helper.connect_with_close(channels, "hb-stale-control", fn() {
      process.send(evicted, Nil)
    })
  let frames = app_test_helper.connect(channels, "hb-alive")

  keep_alive_until_evicted(channels, "hb-alive", frames, evicted)
  socket_is_connected(channels, "hb-alive", frames) |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn heartbeat_timeout_only_evicts_stale_sockets_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(500, events)
  let evicted = process.new_subject()
  let _stale_frames =
    app_test_helper.connect_with_close(channels, "hb-idle", fn() {
      process.send(evicted, Nil)
    })
  let active_frames = app_test_helper.connect(channels, "hb-busy")

  keep_alive_until_evicted(channels, "hb-busy", active_frames, evicted)
  socket_is_connected(channels, "hb-busy", active_frames) |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn periodic_check_runs_repeatedly_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(100, events)

  // Let several check cycles pass before this socket even connects; a
  // one-shot check would miss it.
  process.sleep(150)
  let frames = app_test_helper.connect(channels, "hb-late")
  socket_is_connected(channels, "hb-late", frames) |> should.be_true

  process.sleep(300)
  socket_is_connected(channels, "hb-late", frames) |> should.be_false

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn heartbeat_eviction_closes_the_transport_connection_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(100, events)
  let closed = process.new_subject()
  let _frames =
    app_test_helper.connect_with_close(channels, "hb-zombie", fn() {
      process.send(closed, Nil)
    })

  let assert Ok(Nil) = process.receive(closed, 1000)

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn closed_delivered_with_heartbeat_timeout_reason_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(100, events)
  let frames = app_test_helper.connect(channels, "hb-member")
  app_test_helper.join(channels, "hb-member", "room:lobby", "j1", "r1")
  let _join_reply = app_test_helper.recv(frames)

  // Wait for eviction, then find the Closed event among the observed ones.
  wait_for_closed(events)

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

fn wait_for_closed(events: process.Subject(socket.Input(Nil))) -> Nil {
  let assert Ok(ev) = process.receive(events, 1000)
  case ev {
    socket.Closed("room:lobby", socket.HeartbeatTimeout) -> Nil
    _ -> wait_for_closed(events)
  }
}

pub fn eviction_cleans_topic_but_keeps_other_members_test() -> Nil {
  let events = process.new_subject()
  let channels = start_hb_app(500, events)
  let evicted = process.new_subject()

  let stale_frames =
    app_test_helper.connect_with_close(channels, "hb-gone", fn() {
      process.send(evicted, Nil)
    })
  app_test_helper.join(channels, "hb-gone", "room:shared", "j1", "r1")
  let _ = app_test_helper.recv(stale_frames)

  let active_frames = app_test_helper.connect(channels, "hb-here")
  app_test_helper.join(channels, "hb-here", "room:shared", "j2", "r2")
  let _ = app_test_helper.recv(active_frames)
  keep_alive_until_evicted(channels, "hb-here", active_frames, evicted)

  // The surviving member still receives topic broadcasts.
  drain(active_frames)
  beryl.broadcast(
    channels,
    "room:shared",
    "ping",
    json.object([#("ok", json.bool(True))]),
  )
  let frame = app_test_helper.recv(active_frames)
  string.contains(frame, "ping") |> should.be_true

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// ── start_app heartbeat config validation ────────────────────────────────
//
// The server derives its check interval as `heartbeat_timeout_ms / 2`
// (integer division), so a timeout of 1 would round the check interval down
// to 0 and silently disable eviction. `child_spec` rejects timeouts below 2.

pub fn start_app_rejects_timeout_of_one_test() -> Nil {
  start_trivial(1)
  |> should.equal(Error(beryl.HeartbeatTimeoutTooLow(2)))
}

pub fn start_app_rejects_zero_timeout_test() -> Nil {
  start_trivial(0)
  |> should.equal(Error(beryl.HeartbeatTimeoutTooLow(2)))
}

pub fn start_app_rejects_negative_timeout_test() -> Nil {
  start_trivial(-5)
  |> should.equal(Error(beryl.HeartbeatTimeoutTooLow(2)))
}

pub fn start_app_accepts_timeout_of_two_test() -> Nil {
  let assert Ok(channels) = start_trivial(2)
  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn start_app_accepts_default_timeout_test() -> Nil {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
      update: fn(model, _ev) { Next(model, []) },
    )
  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

fn start_trivial(timeout_ms: Int) -> Result(beryl.Sockets, beryl.ConfigError) {
  app_test_helper.start_app(
    beryl.config(wire.phoenix_codec())
      |> beryl.with_heartbeat(timeout_ms: timeout_ms),
    init: fn(_info: socket.ConnectInfo(Nil)) { #(Nil, []) },
    update: fn(model, _ev) { Next(model, []) },
  )
}
