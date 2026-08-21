import app_test_helpers as h
import beryl
import beryl/socket
import beryl/stats
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should
import test_helpers

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
  test_helpers.wait_until(
    fn() { stats.connected_sockets(read_snapshot(sockets)) == 1 },
    500,
    10,
  )
  let after_disconnect = read_snapshot(sockets)
  stats.connected_sockets(after_disconnect) |> should.equal(1)
  stats.joined_socket_topic_pairs(after_disconnect) |> should.equal(2)
  stats.active_topics(after_disconnect) |> should.equal(2)

  let _ = beryl.stop(sockets)
}

/// A socket actor that dies without reporting `SocketClosed` (killed, or
/// crashed outside a rescue boundary) must be swept by the router's
/// monitor: neither its connection count nor its topic-index entries may
/// leak.
pub fn a_killed_socket_actor_is_swept_from_the_router_test() {
  let pids = process.new_subject()
  let assert Ok(sockets) =
    h.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) {
        // `init` runs in the socket's own actor, so this is the actor pid.
        process.send(pids, process.self())
        #(Nil, [])
      },
      update: fn(model, input) {
        case input {
          socket.Join(_, _, ref) ->
            socket.Next(model, [socket.AcceptJoin(ref, None)])
          _ -> socket.Next(model, [])
        }
      },
    )
  let frames = h.connect(sockets, "doomed")
  h.join(sockets, "doomed", "room:x", "jr-1", "1")
  let assert Ok(_) = process.receive(frames, 500)
  let assert Ok(actor_pid) = process.receive(pids, 500)
    as "init reported the socket actor's pid"
  test_helpers.wait_until(
    fn() { stats.connected_sockets(read_snapshot(sockets)) == 1 },
    500,
    10,
  )
  let joined = read_snapshot(sockets)
  stats.active_topics(joined) |> should.equal(1)

  process.kill(actor_pid)

  test_helpers.wait_until(
    fn() { stats.connected_sockets(read_snapshot(sockets)) == 0 },
    500,
    10,
  )
  let swept = read_snapshot(sockets)
  stats.joined_socket_topic_pairs(swept) |> should.equal(0)
  stats.active_topics(swept) |> should.equal(0)
  let _ = beryl.stop(sockets)
}

pub fn snapshot_returns_unavailable_after_stop_test() {
  let sockets = start_sockets()
  let assert Ok(Nil) = beryl.stop(sockets)
  stats.snapshot(sockets)
  |> should.equal(Error(stats.RuntimeUnavailable))
}

/// The positive pin of #334's topology: an app callback blocks only its
/// own socket's actor, so the router answers stats requests while a
/// callback is mid-flight. (A flooded router can still return
/// `RequestTimedOut`; `snapshot_returns_unavailable_after_stop_test`
/// covers the unavailable path.)
pub fn snapshot_succeeds_while_a_socket_callback_is_busy_test() {
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

  let snapshot = read_snapshot(sockets)
  stats.connected_sockets(snapshot) |> should.equal(1)
  stats.joined_socket_topic_pairs(snapshot) |> should.equal(1)
  stats.active_topics(snapshot) |> should.equal(1)
  let _ = beryl.stop(sockets)
}
