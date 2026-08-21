import app_test_helpers as h
import beryl
import beryl/socket
import beryl/stats
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should

fn start_sockets() -> beryl.Sockets {
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, input) {
        case input {
          socket.Join(_, _, ref) ->
            socket.Next(model, [socket.AcceptJoin(ref, None)])
          _ -> socket.Next(model, [])
        }
      },
    )
  sockets
}

fn read_snapshot(sockets: beryl.Sockets) -> stats.Snapshot {
  let assert Ok(snapshot) = stats.snapshot(sockets)
  snapshot
}

/// Snapshots are documented as eventually consistent: counts may lag
/// in-flight lifecycle notifications. Poll until the predicate holds, then
/// return the snapshot for exact assertions; fail loudly on timeout.
fn read_until(
  sockets: beryl.Sockets,
  predicate: fn(stats.Snapshot) -> Bool,
  deadline_ms: Int,
) -> stats.Snapshot {
  let snapshot = read_snapshot(sockets)
  case predicate(snapshot), deadline_ms > 0 {
    True, _ -> snapshot
    False, True -> {
      process.sleep(10)
      read_until(sockets, predicate, deadline_ms - 10)
    }
    False, False -> {
      should.be_true(False)
      snapshot
    }
  }
}

pub fn snapshot_tracks_socket_lifecycle_test() {
  let sockets = start_sockets()
  let initial = read_snapshot(sockets)
  stats.connected_sockets(initial) |> should.equal(0)
  stats.joined_socket_topic_pairs(initial) |> should.equal(0)
  stats.active_topics(initial) |> should.equal(0)

  let first = h.connect(sockets, "socket-1")
  let second = h.connect(sockets, "socket-2")
  h.join(sockets, "socket-1", "room:a", "jr-1", "1")
  h.join(sockets, "socket-1", "room:b", "jr-2", "2")
  h.join(sockets, "socket-2", "room:a", "jr-3", "3")
  let assert Ok(_) = process.receive(first, 500)
  let assert Ok(_) = process.receive(first, 500)
  let assert Ok(_) = process.receive(second, 500)

  let joined = read_snapshot(sockets)
  stats.connected_sockets(joined) |> should.equal(2)
  stats.joined_socket_topic_pairs(joined) |> should.equal(3)
  stats.active_topics(joined) |> should.equal(2)

  transport.socket_disconnected(sockets, "socket-2")
  let after_disconnect =
    read_until(
      sockets,
      fn(snapshot) { stats.connected_sockets(snapshot) == 1 },
      500,
    )
  stats.connected_sockets(after_disconnect) |> should.equal(1)
  stats.joined_socket_topic_pairs(after_disconnect) |> should.equal(2)
  stats.active_topics(after_disconnect) |> should.equal(2)

  let _ = beryl.stop(sockets)
}

pub fn snapshot_returns_unavailable_after_stop_test() {
  let sockets = start_sockets()
  let assert Ok(Nil) = beryl.stop(sockets)
  stats.snapshot(sockets)
  |> should.equal(Error(stats.RuntimeUnavailable))
}

pub fn snapshot_times_out_while_runtime_is_busy_test() {
  let entered = process.new_subject()
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, input) {
        case input {
          socket.Join(_, _, ref) ->
            socket.Next(model, [socket.AcceptJoin(ref, None)])
          socket.Message(_, "block", _, _) -> {
            process.send(entered, Nil)
            process.sleep(1200)
            socket.Next(model, [])
          }
          _ -> socket.Next(model, [])
        }
      },
    )
  let frames = h.connect(sockets, "slow")
  h.join(sockets, "slow", "room:slow", "jr", "join")
  let assert Ok(_) = process.receive(frames, 500)
  h.push(sockets, "slow", "room:slow", "block", "ref")
  let assert Ok(Nil) = process.receive(entered, 500)

  stats.snapshot(sockets)
  |> should.equal(Error(stats.RequestTimedOut))
  let _ = beryl.stop(sockets)
}
