import app_test_helper
import beryl
import beryl/presence
import beryl/snapshot
import beryl/socket
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleeunit/should
import test_helper

fn start_sockets() -> beryl.Sockets {
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, input) {
        case input {
          socket.Join(_, _, ref) ->
            socket.Next(model, [socket.AcceptJoin(ref, None)])
          socket.Message(_, _, _, _)
          | socket.Binary(_, _)
          | socket.Closed(_, _)
          | socket.Info(_) -> socket.Next(model, [])
        }
      },
    )
  sockets
}

fn read_snapshot(sockets: beryl.Sockets) -> snapshot.Snapshot {
  let assert Ok(runtime_snapshot) = snapshot.get(sockets)
  runtime_snapshot
}

pub fn snapshot_tracks_socket_lifecycle_test() -> Nil {
  let sockets = start_sockets()
  let initial = read_snapshot(sockets)
  snapshot.connected_sockets(initial) |> should.equal(0)
  snapshot.joined_socket_topic_pairs(initial) |> should.equal(0)
  snapshot.active_topics(initial) |> should.equal(0)

  let first = app_test_helper.connect(sockets, "socket-1")
  let second = app_test_helper.connect(sockets, "socket-2")
  app_test_helper.join(sockets, "socket-1", "room:a", "jr-1", "1")
  app_test_helper.join(sockets, "socket-1", "room:b", "jr-2", "2")
  app_test_helper.join(sockets, "socket-2", "room:a", "jr-3", "3")
  let assert Ok(_) = process.receive(first, 500)
  let assert Ok(_) = process.receive(first, 500)
  let assert Ok(_) = process.receive(second, 500)

  let joined = read_snapshot(sockets)
  snapshot.connected_sockets(joined) |> should.equal(2)
  snapshot.joined_socket_topic_pairs(joined) |> should.equal(3)
  snapshot.active_topics(joined) |> should.equal(2)

  transport.socket_disconnected(sockets, "socket-2")
  test_helper.wait_until(
    fn() { snapshot.connected_sockets(read_snapshot(sockets)) == 1 },
    500,
    10,
  )
  let after_disconnect = read_snapshot(sockets)
  snapshot.connected_sockets(after_disconnect) |> should.equal(1)
  snapshot.joined_socket_topic_pairs(after_disconnect) |> should.equal(2)
  snapshot.active_topics(after_disconnect) |> should.equal(2)

  let _ = beryl.stop(sockets)
  Nil
}

/// A socket actor that dies without reporting `SocketClosed` (killed, or
/// crashed outside a rescue boundary) must be swept by the router's
/// monitor: neither its connection count nor its topic-index entries may
/// leak.
pub fn a_killed_socket_actor_is_swept_from_the_router_test() -> Nil {
  let pids = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(presence_handle) =
    presence.start(presence.default_config("snapshot-actor-crash"))
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_presence_handle(presence_handle),
      init: fn(_info) {
        // `init` runs in the socket's own actor, so this is the actor pid.
        process.send(pids, process.self())
        #(Nil, [])
      },
      update: fn(model, input) {
        case input {
          socket.Join(topic_name, _, ref) ->
            socket.Next(model, [
              socket.AcceptJoin(ref, None),
              socket.PresenceTrack(topic_name, "tracked", json.object([])),
            ])
          socket.Message(_, _, _, _)
          | socket.Binary(_, _)
          | socket.Closed(_, _)
          | socket.Info(_) -> socket.Next(model, [])
        }
      },
    )
  let frames =
    app_test_helper.connect_with_close(sockets, "doomed", fn() {
      process.send(closed, Nil)
    })
  app_test_helper.join(sockets, "doomed", "room:x", "jr-1", "1")
  let assert Ok(_) = process.receive(frames, 500)
  let assert Ok(actor_pid) = process.receive(pids, 500)
    as "init reported the socket actor's pid"
  test_helper.wait_until(
    fn() { snapshot.connected_sockets(read_snapshot(sockets)) == 1 },
    500,
    10,
  )
  let joined = read_snapshot(sockets)
  snapshot.active_topics(joined) |> should.equal(1)
  test_helper.wait_until(
    fn() {
      case presence.list(presence_handle, "room:x") {
        Ok([_]) -> True
        Ok(_) | Error(Nil) -> False
      }
    },
    500,
    10,
  )

  process.kill(actor_pid)

  process.receive(closed, 500) |> should.equal(Ok(Nil))
  test_helper.wait_until(
    fn() { snapshot.connected_sockets(read_snapshot(sockets)) == 0 },
    500,
    10,
  )
  let swept = read_snapshot(sockets)
  snapshot.joined_socket_topic_pairs(swept) |> should.equal(0)
  snapshot.active_topics(swept) |> should.equal(0)
  test_helper.wait_until(
    fn() { presence.list(presence_handle, "room:x") == Ok([]) },
    500,
    10,
  )
  let _ = beryl.stop(sockets)
  Nil
}

pub fn snapshot_returns_unavailable_after_stop_test() -> Nil {
  let sockets = start_sockets()
  let assert Ok(Nil) = beryl.stop(sockets)
  snapshot.get(sockets)
  |> should.equal(Error(snapshot.RuntimeUnavailable))
}

/// The positive pin of #334's topology: an app callback blocks only its
/// own socket's actor, so the router answers snapshot requests while a
/// callback is mid-flight. (A flooded router can still return
/// `RequestTimedOut`; `snapshot_returns_unavailable_after_stop_test`
/// covers the unavailable path.)
pub fn snapshot_succeeds_while_a_socket_callback_is_busy_test() -> Nil {
  let entered = process.new_subject()
  let assert Ok(sockets) =
    app_test_helper.start_app(
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
          socket.Message(_, _, _, _)
          | socket.Binary(_, _)
          | socket.Closed(_, _)
          | socket.Info(_) -> socket.Next(model, [])
        }
      },
    )
  let frames = app_test_helper.connect(sockets, "slow")
  app_test_helper.join(sockets, "slow", "room:slow", "jr", "join")
  let assert Ok(_) = process.receive(frames, 500)
  app_test_helper.push(sockets, "slow", "room:slow", "block", "ref")
  let assert Ok(Nil) = process.receive(entered, 500)

  let runtime_snapshot = read_snapshot(sockets)
  snapshot.connected_sockets(runtime_snapshot) |> should.equal(1)
  snapshot.joined_socket_topic_pairs(runtime_snapshot) |> should.equal(1)
  snapshot.active_topics(runtime_snapshot) |> should.equal(1)
  let _ = beryl.stop(sockets)
  Nil
}
