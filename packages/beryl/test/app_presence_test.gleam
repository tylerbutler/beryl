//// Presence effects: `PresenceTrack`/`PresenceUntrack` update the actor
//// and broadcast `presence_diff`s; `PushPresence`/`BroadcastPresence`
//// encode their snapshot at apply time (after earlier presence effects in
//// the same list); leftover tracked keys are auto-untracked when their
//// topic closes.

import app_test_helper
import beryl
import beryl/presence
import beryl/socket.{
  AcceptJoin, BroadcastPresence, Join, Message, Next, PresenceTrack,
  PresenceUntrack, PushPresence,
}
import beryl/wire
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import test_helper

pub fn main() -> Nil {
  gleeunit.main()
}

/// Encode presence entries as `{session_id: meta}` — the examples'
/// `presence_list` shape.
fn encode_users(entries: List(presence.PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.session_id, entry.meta) }))
}

/// Joins track the socket under "user:1" and broadcast an apply-time
/// snapshot; "untrack" untracks and re-broadcasts; "who" pushes a snapshot
/// to the requesting socket only.
fn start_system(p: presence.Presence) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
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
                json.object([#("status", json.string("online"))]),
              ),
              BroadcastPresence(topic, "presence_list", encode_users),
            ])
          Message(topic, "untrack", _payload, _ref) ->
            Next(model, [
              PresenceUntrack(topic, "user:1"),
              BroadcastPresence(topic, "presence_list", encode_users),
            ])
          Message(topic, "who", _payload, _ref) ->
            Next(model, [PushPresence(topic, "who_list", encode_users)])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

pub fn presence_track_updates_actor_and_broadcasts_diff_test() -> Nil {
  let assert Ok(p) = presence.start(presence.default_config("node1"))
  let channels = start_system(p)
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  // Join ack first, then the presence_diff broadcast (self is subscribed
  // by then, so it sees its own join diff).
  let reply = app_test_helper.recv(frames)
  reply |> string.contains("phx_reply") |> should.be_true
  let diff = app_test_helper.recv(frames)
  diff |> string.contains("presence_diff") |> should.be_true
  diff |> string.contains("user:1") |> should.be_true
  diff |> string.contains("online") |> should.be_true

  // The presence actor has the entry.
  test_helper.wait_until(
    fn() { list.length(presence_entries(p, "room:a")) == 1 },
    2000,
    20,
  )
  let assert [entry] = presence_entries(p, "room:a")
  entry.key |> should.equal("user:1")
}

pub fn broadcast_presence_snapshot_sees_same_list_track_test() -> Nil {
  let assert Ok(p) = presence.start(presence.default_config("node1"))
  let channels = start_system(p)
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  let _reply = app_test_helper.recv(frames)
  let _diff = app_test_helper.recv(frames)
  // The snapshot was encoded AFTER the PresenceTrack earlier in the same
  // effects list, so it already contains the joining user — the exact
  // staleness a payload built inside `update` would have.
  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("s1") |> should.be_true
  snapshot |> string.contains("online") |> should.be_true
}

pub fn presence_untrack_broadcasts_leave_and_empty_snapshot_test() -> Nil {
  let assert Ok(p) = presence.start(presence.default_config("node1"))
  let channels = start_system(p)
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  let _join_diff = app_test_helper.recv(frames)
  let _join_snapshot = app_test_helper.recv(frames)

  app_test_helper.push(channels, "s1", "room:a", "untrack", "r-2")

  let leave_diff = app_test_helper.recv(frames)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  leave_diff |> string.contains("leaves") |> should.be_true
  leave_diff |> string.contains("user:1") |> should.be_true

  // The snapshot after the untrack no longer contains the socket.
  let snapshot = app_test_helper.recv(frames)
  snapshot |> string.contains("presence_list") |> should.be_true
  snapshot |> string.contains("s1\":") |> should.be_false

  test_helper.wait_until(fn() { presence_entries(p, "room:a") == [] }, 2000, 20)
}

pub fn push_presence_goes_only_to_requester_test() -> Nil {
  let assert Ok(p) = presence.start(presence.default_config("node1"))
  let channels = start_system(p)
  let frames1 = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply1 = app_test_helper.recv(frames1)
  let _diff1 = app_test_helper.recv(frames1)
  let _snapshot1 = app_test_helper.recv(frames1)
  let frames2 = app_test_helper.connect(channels, "s2")
  app_test_helper.join(channels, "s2", "room:a", "jr-2", "r-2")
  let _reply2 = app_test_helper.recv(frames2)
  // s1 sees s2's join diff + snapshot; drain them.
  let _diff_s2 = app_test_helper.recv(frames1)
  let _snapshot_s2 = app_test_helper.recv(frames1)
  let _diff2 = app_test_helper.recv(frames2)
  let _snapshot2 = app_test_helper.recv(frames2)

  app_test_helper.push(channels, "s1", "room:a", "who", "r-3")

  // Only the requesting socket receives the pushed snapshot.
  let who = app_test_helper.recv(frames1)
  who |> string.contains("who_list") |> should.be_true
  app_test_helper.recv_none(frames2)
}

pub fn leftover_presence_is_untracked_when_topic_closes_test() -> Nil {
  let assert Ok(p) = presence.start(presence.default_config("node1"))
  let channels = start_system(p)

  // A second socket stays in the room to observe the leave diff.
  let frames_watcher = app_test_helper.connect(channels, "watcher")
  app_test_helper.join(channels, "watcher", "room:a", "jr-w", "r-w")
  let _watcher_reply = app_test_helper.recv(frames_watcher)
  let _watcher_diff = app_test_helper.recv(frames_watcher)
  let _watcher_snapshot = app_test_helper.recv(frames_watcher)

  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _reply = app_test_helper.recv(frames)
  // Watcher sees s1's join diff + snapshot.
  let _s1_join_diff = app_test_helper.recv(frames_watcher)
  let _s1_join_snapshot = app_test_helper.recv(frames_watcher)

  test_helper.wait_until(
    fn() { list.length(presence_entries(p, "room:a")) == 2 },
    2000,
    20,
  )

  // s1 leaves without untracking: the runtime auto-untracks and the
  // watcher sees the leave diff.
  app_test_helper.route(
    channels,
    "s1",
    "[\"jr-1\",\"r-2\",\"room:a\",\"phx_leave\",{}]",
  )

  let leave_diff = app_test_helper.recv(frames_watcher)
  leave_diff |> string.contains("presence_diff") |> should.be_true
  leave_diff |> string.contains("leaves") |> should.be_true

  test_helper.wait_until(
    fn() { list.length(presence_entries(p, "room:a")) == 1 },
    2000,
    20,
  )
}

pub fn presence_effects_without_handle_are_dropped_test() -> Nil {
  // No with_presence_handle: track and snapshot effects are dropped with
  // warnings and the join still succeeds.
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, ev: socket.Input(Nil)) {
        case ev {
          Join(topic, _payload, ref) ->
            Next(model, [
              AcceptJoin(ref, Some(json.object([]))),
              PresenceTrack(topic, "user:1", json.object([])),
              BroadcastPresence(topic, "presence_list", encode_users),
            ])
          _ -> Next(model, [])
        }
      },
    )
  let frames = app_test_helper.connect(channels, "s1")
  app_test_helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let reply = app_test_helper.recv(frames)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  app_test_helper.recv_none(frames)
}

fn presence_entries(
  tracker: presence.Presence,
  topic: String,
) -> List(presence.PresenceEntry) {
  let assert Ok(entries) = presence.list(tracker, topic)
  entries
}
