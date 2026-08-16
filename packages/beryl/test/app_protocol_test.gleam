//// Protocol hardening for app-side dispatch: reserved `beryl:` topics are
//// rejected, client-forged reserved `phx_*` events never reach the app,
//// messages/leaves carrying a stale `join_ref` after a rejoin are dropped,
//// and unjoined events without a reply ref are dropped silently.

import app_test_helpers as h
import beryl
import beryl/socket.{Closed, Join, Message}
import beryl/wire
import gleam/erlang/process
import gleam/string
import gleeunit/should

fn start_system(events: process.Subject(socket.Input(Nil))) -> beryl.Sockets {
  h.start_observed(beryl.config(wire.phoenix_codec()), events)
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

pub fn join_to_reserved_beryl_topic_is_rejected_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = h.connect(channels, "s1")

  h.join(channels, "s1", "beryl:internal", "jr-1", "r-1")

  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
  // The reserved join never reached the app.
  process.receive(events, 100) |> should.be_error
}

pub fn forged_reserved_phx_event_is_dropped_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // A client-sent reserved event is dropped before dispatch: no frame, no
  // app event.
  h.route(channels, "s1", event_frame("jr-1", "r-2", "room:a", "phx_reply"))
  h.recv_none(frames)
  process.receive(events, 100) |> should.be_error

  // A normal event on the same topic still reaches the app.
  h.route(channels, "s1", event_frame("jr-1", "r-3", "room:a", "shout"))
  let assert Ok(Message("room:a", "shout", _, _)) = process.receive(events, 500)
}

pub fn stale_join_ref_message_is_dropped_after_rejoin_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply1 = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)

  // Rejoin under a new join_ref: the old instance closes, the new one is live.
  h.join(channels, "s1", "room:a", "jr-2", "r-2")
  let assert Ok(Closed("room:a", socket.Normal)) = process.receive(events, 500)
  let _close = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  let _reply2 = h.recv(frames)

  // A message tagged with the stale join_ref is dropped.
  h.route(channels, "s1", event_frame("jr-1", "r-3", "room:a", "stale"))
  process.receive(events, 100) |> should.be_error

  // A message with the current join_ref is delivered.
  h.route(channels, "s1", event_frame("jr-2", "r-4", "room:a", "fresh"))
  let assert Ok(Message("room:a", "fresh", _, _)) = process.receive(events, 500)
}

pub fn stale_join_ref_leave_is_ignored_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply1 = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  h.join(channels, "s1", "room:a", "jr-2", "r-2")
  let assert Ok(Closed("room:a", socket.Normal)) = process.receive(events, 500)
  let _close = h.recv(frames)
  let assert Ok(Join(_, _, _)) = process.receive(events, 500)
  let _reply2 = h.recv(frames)

  // A leave carrying the stale join_ref does not close the current instance.
  h.route(channels, "s1", "[\"jr-1\",\"r-3\",\"room:a\",\"phx_leave\",{}]")
  process.receive(events, 100) |> should.be_error
  h.recv_none(frames)

  // The current instance is still joined and serving.
  h.route(channels, "s1", event_frame("jr-2", "r-4", "room:a", "still_here"))
  let assert Ok(Message("room:a", "still_here", _, _)) =
    process.receive(events, 500)
}

pub fn unjoined_event_without_ref_is_dropped_test() {
  let events = process.new_subject()
  let channels = start_system(events)
  let frames = h.connect(channels, "s1")

  // An event on a topic the socket never joined, with no reply ref, is
  // dropped: no error frame, no app event.
  h.route(channels, "s1", "[null,null,\"room:a\",\"noop\",{}]")
  h.recv_none(frames)
  process.receive(events, 100) |> should.be_error
}
