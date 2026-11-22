//// Protocol hardening for app-side dispatch: reserved `beryl:` topics are
//// rejected, client-forged reserved `phx_*` events never reach the app,
//// messages/leaves carrying a stale `join_ref` after a rejoin are dropped,
//// and unjoined events without a reply ref are dropped silently.

import app_test_helper
import beryl
import beryl/socket.{Closed, Join, Message}
import beryl/wire
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit/should
import test_helper

fn start_system(events: process.Subject(socket.Input(Nil))) -> beryl.Sockets {
  app_test_helper.start_observed(beryl.config(wire.phoenix_codec()), events)
}

fn event_frame(
  join_ref: String,
  ref: String,
  topic_name: String,
  event_name: String,
) -> String {
  "[\""
  <> join_ref
  <> "\",\""
  <> ref
  <> "\",\""
  <> topic_name
  <> "\",\""
  <> event_name
  <> "\",{}]"
}

pub fn join_to_reserved_beryl_topic_is_rejected_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = app_test_helper.connect(channels, "s1")

  app_test_helper.join(channels, "s1", "beryl:internal", "jr-1", "r-1")

  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
  // The reserved join never reached the app.
  process.receive(events, 100) |> should.be_error
}

pub fn forged_reserved_phx_event_is_dropped_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // A client-sent reserved event is dropped before dispatch: no frame, no
  // app event.
  app_test_helper.route(
    channels,
    "s1",
    event_frame("jr-1", "r-2", "room:a", "phx_reply"),
  )
  app_test_helper.recv_none(frames)
  process.receive(events, 100) |> should.be_error

  // A normal event on the same topic still reaches the app.
  app_test_helper.route(
    channels,
    "s1",
    event_frame("jr-1", "r-3", "room:a", "shout"),
  )
  let assert Ok(Message("room:a", "shout", _, _)) = process.receive(events, 500)
  Nil
}

pub fn stale_join_ref_message_is_dropped_after_rejoin_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply1 = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // Rejoin under a new join_ref: the old instance closes, the new one is live.
  app_test_helper.join(channels, "s1", "room:a", "jr-2", "r-2")
  let assert Ok(Closed("room:a", socket.Normal)) = process.receive(events, 500)
  let _close = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  let _reply2 = app_test_helper.recv(frames)

  // A message tagged with the stale join_ref is dropped.
  app_test_helper.route(
    channels,
    "s1",
    event_frame("jr-1", "r-3", "room:a", "stale"),
  )
  process.receive(events, 100) |> should.be_error

  // A message with the current join_ref is delivered.
  app_test_helper.route(
    channels,
    "s1",
    event_frame("jr-2", "r-4", "room:a", "fresh"),
  )
  let assert Ok(Message("room:a", "fresh", _, _)) = process.receive(events, 500)
  Nil
}

pub fn stale_join_ref_leave_is_ignored_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply1 = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  app_test_helper.join(channels, "s1", "room:a", "jr-2", "r-2")
  let assert Ok(Closed("room:a", socket.Normal)) = process.receive(events, 500)
  let _close = app_test_helper.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  let _reply2 = app_test_helper.recv(frames)

  // A leave carrying the stale join_ref does not close the current instance.
  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-3\",\"room:a\",\"phx_leave\",{}]",
  )
  process.receive(events, 100) |> should.be_error
  app_test_helper.recv_none(frames)

  // The current instance is still joined and serving.
  app_test_helper.route(
    channels,
    "s1",
    event_frame("jr-2", "r-4", "room:a", "still_here"),
  )
  let assert Ok(Message("room:a", "still_here", _, _)) =
    process.receive(events, 500)
  Nil
}

pub fn unjoined_event_without_ref_is_dropped_test() -> Nil {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = app_test_helper.connect(channels, "s1")

  // An event on a topic the socket never joined, with no reply ref, is
  // dropped: no error frame, no app event.
  app_test_helper.route(channels, "s1", "[null,null,\"room:a\",\"noop\",{}]")
  app_test_helper.recv_none(frames)
  process.receive(events, 100) |> should.be_error
}

pub fn stale_leave_queued_during_replacement_callback_preserves_join_test() -> Nil {
  use <- test_helper.with_isolated_caller(5000)
  let entered = process.new_subject()
  let delivered = process.new_subject()
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(0, []) },
      update: fn(joins, input) {
        case input {
          Join(_, _, ref) -> {
            case joins {
              0 -> Nil
              _ -> {
                let release = process.new_subject()
                process.send(entered, release)
                process.receive(release, 1000) |> should.equal(Ok(Nil))
              }
            }
            socket.Next(joins + 1, [socket.AcceptJoin(ref, None)])
          }
          Message(_, event, _, _) -> {
            process.send(delivered, event)
            socket.Next(joins, [])
          }
          socket.Binary(..) | Closed(..) | socket.Info(..) ->
            socket.Next(joins, [])
        }
      },
    )
  let frames = app_test_helper.connect(channels, "replacement")
  app_test_helper.join_ok(channels, frames, "replacement", "room:a", "j1", "r1")
  app_test_helper.join(channels, "replacement", "room:a", "j2", "r2")
  let terminal = app_test_helper.recv(frames)
  terminal |> string.contains("\"phx_close\"") |> should.be_true
  let assert Ok(release) = process.receive(entered, 1000)
  app_test_helper.route(
    channels,
    "replacement",
    "[\"j1\",\"old-leave\",\"room:a\",\"phx_leave\",{}]",
  )
  process.send(release, Nil)
  app_test_helper.recv(frames)
  |> should.equal(
    "[\"j2\",\"r2\",\"room:a\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  )
  app_test_helper.route(
    channels,
    "replacement",
    event_frame("j2", "barrier", "room:a", "current"),
  )
  process.receive(delivered, 1000) |> should.equal(Ok("current"))
  app_test_helper.recv_none(frames)
  beryl.stop(channels) |> should.equal(Ok(Nil))
}
