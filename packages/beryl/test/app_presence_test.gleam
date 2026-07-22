//// Presence effects (`PresenceTrack`/`PresenceUntrack`): tracking updates
//// the presence actor and broadcasts `presence_diff` joins; untracking
//// broadcasts leaves; leftover tracked keys are auto-untracked when their
//// topic closes.

import app_test_helpers as h
import beryl
import beryl/event.{
  AcceptJoin, Join, Message, Next, PresenceTrack, PresenceUntrack,
}
import beryl/presence
import beryl/wire
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import test_helpers

pub fn main() {
  gleeunit.main()
}

/// Joins track the socket under the "user:<ref>" key from the join ref;
/// "untrack" untracks it explicitly.
fn start_system(p: presence.Presence) -> beryl.Channels {
  let assert Ok(channels) =
    beryl.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_presence_handle(p),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(topic, _payload, ref) ->
            Next(model, [
              AcceptJoin(ref, None),
              PresenceTrack(
                topic,
                "user:1",
                json.object([
                  #("status", json.string("online")),
                ]),
              ),
            ])
          Message(topic, "untrack", _payload, _ref) ->
            Next(model, [PresenceUntrack(topic, "user:1")])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

pub fn presence_track_updates_actor_and_broadcasts_diff_test() {
  let assert Ok(p) = presence.start(presence.default_config("node1"))
  let channels = start_system(p)
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")

  // Join ack first, then the presence_diff broadcast (self is subscribed
  // by then, so it sees its own join diff).
  let reply = h.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  let diff = h.recv(frames)
  diff |> string.contains("presence_diff") |> should.be_true
  diff |> string.contains("user:1") |> should.be_true
  diff |> string.contains("online") |> should.be_true

  // The presence actor has the entry.
  test_helpers.wait_until(
    fn() { list.length(presence.list(p, "room:a")) == 1 },
    2000,
    20,
  )
  let assert [entry] = presence.list(p, "room:a")
  entry.key |> should.equal("user:1")
}

pub fn presence_untrack_broadcasts_leave_test() {
  let assert Ok(p) = presence.start(presence.default_config("node1"))
  let channels = start_system(p)
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  let _join_diff = h.recv(frames)

  h.push(channels, "s1", "room:a", "untrack", "r-2")

  let leave_diff = h.recv(frames)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  leave_diff |> string.contains("leaves") |> should.be_true
  leave_diff |> string.contains("user:1") |> should.be_true

  test_helpers.wait_until(fn() { presence.list(p, "room:a") == [] }, 2000, 20)
}

pub fn leftover_presence_is_untracked_when_topic_closes_test() {
  let assert Ok(p) = presence.start(presence.default_config("node1"))
  let channels = start_system(p)

  // A second socket stays in the room to observe the leave diff.
  let frames_watcher = h.connect(channels, "watcher")
  h.join(channels, "watcher", "room:a", "jr-w", "r-w")
  let _watcher_reply = h.recv(frames_watcher)
  let _watcher_diff = h.recv(frames_watcher)

  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = h.recv(frames)
  // Watcher sees s1's join diff.
  let _s1_join_diff = h.recv(frames_watcher)

  test_helpers.wait_until(
    fn() { list.length(presence.list(p, "room:a")) == 2 },
    2000,
    20,
  )

  // s1 leaves without untracking: the runtime auto-untracks and the
  // watcher sees the leave diff.
  h.route(channels, "s1", "[\"jr-1\",\"r-2\",\"room:a\",\"phx_leave\",{}]")

  let leave_diff = h.recv(frames_watcher)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  leave_diff |> string.contains("leaves") |> should.be_true

  test_helpers.wait_until(
    fn() { list.length(presence.list(p, "room:a")) == 1 },
    2000,
    20,
  )
}

pub fn presence_track_without_handle_is_dropped_test() {
  // No with_presence_handle: the track effect is dropped with a warning
  // and the join still succeeds.
  let assert Ok(channels) =
    beryl.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, ev: event.Event(Nil)) {
        case ev {
          Join(topic, _payload, ref) ->
            Next(model, [
              AcceptJoin(ref, Some(json.object([]))),
              PresenceTrack(topic, "user:1", json.object([])),
            ])
          _ -> Next(model, [])
        }
      },
    )
  let frames = h.connect(channels, "s1")
  h.join(channels, "s1", "room:a", "jr-1", "r-1")
  let reply = h.recv(frames)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  h.recv_none(frames)
}
