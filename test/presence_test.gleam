import beryl/presence
import gleam/erlang/process
import gleam/json
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn test_config(replica: String) -> presence.Config {
  presence.default_config(replica)
}

pub fn presence_start_test() {
  let result = presence.start(test_config("node1"))
  should.be_ok(result)
}

pub fn presence_track_and_list_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let meta = json.object([#("status", json.string("online"))])
  let _ref = presence.track(p, "room:lobby", "user:1", "socket-1", meta)

  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(1)

  let assert [entry] = entries
  entry.pid |> should.equal("socket-1")
  entry.key |> should.equal("user:1")
}

pub fn presence_track_multiple_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.string("meta1"))
  let _ =
    presence.track(p, "room:lobby", "user:2", "socket-2", json.string("meta2"))

  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(2)
}

pub fn presence_untrack_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  presence.untrack(p, "room:lobby", "user:1", "socket-1")

  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(0)
}

pub fn presence_untrack_all_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p, "room:general", "user:1", "socket-1", json.null())

  // Both topics have entries from socket-1
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)
  list.length(presence.list(p, "room:general")) |> should.equal(1)

  // Untrack all for socket-1
  presence.untrack_all(p, "socket-1")

  list.length(presence.list(p, "room:lobby")) |> should.equal(0)
  list.length(presence.list(p, "room:general")) |> should.equal(0)
}

pub fn presence_get_by_key_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let meta1 = json.object([#("device", json.string("desktop"))])
  let meta2 = json.object([#("device", json.string("mobile"))])
  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", meta1)
  let _ = presence.track(p, "room:lobby", "user:1", "socket-2", meta2)

  let entries = presence.get_by_key(p, "room:lobby", "user:1")
  list.length(entries) |> should.equal(2)
}

pub fn presence_different_topics_isolated_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p, "room:other", "user:2", "socket-2", json.null())

  list.length(presence.list(p, "room:lobby")) |> should.equal(1)
  list.length(presence.list(p, "room:other")) |> should.equal(1)
  list.length(presence.list(p, "room:empty")) |> should.equal(0)
}

pub fn presence_empty_list_test() {
  let assert Ok(p) = presence.start(test_config("node1"))
  let entries = presence.list(p, "room:empty")
  list.length(entries) |> should.equal(0)
}

pub fn presence_default_config_test() {
  let assert Ok(p) = presence.start(presence.default_config("my-node"))
  let _ = presence.track(p, "room:default", "user:1", "socket-1", json.null())

  presence.list(p, "room:default")
  |> list.length
  |> should.equal(1)
}

// ── on_diff callback tests ──────────────────────────────────────────────────

pub fn on_diff_callback_receives_local_track_diff_test() {
  let diff_subject = process.new_subject()

  let config =
    presence.default_config("node1")
    |> presence.with_on_diff(fn(diff) { process.send(diff_subject, diff) })

  let assert Ok(p) = presence.start(config)

  let _ =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("status", json.string("online"))]),
    )

  let assert Ok(diff) = process.receive(diff_subject, 1000)
  presence.diff_topics(diff)
  |> should.equal(["room:lobby"])
  presence.diff_joins(diff, "room:lobby")
  |> should.equal([
    presence.PresenceEntry(
      pid: "socket-1",
      key: "user:1",
      meta: json.object([#("status", json.string("online"))]),
    ),
  ])
  presence.diff_leaves(diff, "room:lobby") |> should.equal([])
}

pub fn on_diff_callback_receives_local_untrack_diff_test() {
  let diff_subject = process.new_subject()

  let config =
    presence.default_config("node1")
    |> presence.with_on_diff(fn(diff) { process.send(diff_subject, diff) })

  let assert Ok(p) = presence.start(config)
  let _ =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("status", json.string("online"))]),
    )
  let assert Ok(_) = process.receive(diff_subject, 1000)

  presence.untrack(p, "room:lobby", "user:1", "socket-1")

  let assert Ok(diff) = process.receive(diff_subject, 1000)
  presence.diff_topics(diff)
  |> should.equal(["room:lobby"])
  presence.diff_joins(diff, "room:lobby") |> should.equal([])
  presence.diff_leaves(diff, "room:lobby")
  |> should.equal([
    presence.PresenceEntry(
      pid: "socket-1",
      key: "user:1",
      meta: json.object([#("status", json.string("online"))]),
    ),
  ])
}

pub fn on_diff_callback_receives_all_rapid_diffs_test() {
  let diff_subject = process.new_subject()

  let config =
    presence.default_config("node1")
    |> presence.with_on_diff(fn(diff) { process.send(diff_subject, diff) })

  let assert Ok(p) = presence.start(config)

  let _ = presence.track(p, "room:lobby", "user:2", "socket-2", json.null())
  let _ = presence.track(p, "room:lobby", "user:3", "socket-3", json.null())

  // Both diffs should have been delivered (no overwrite)
  let assert Ok(diff1) = process.receive(diff_subject, 1000)
  let assert Ok(diff2) = process.receive(diff_subject, 1000)

  // First diff: user:2 joined
  let joins1 = presence.diff_joins(diff1, "room:lobby")
  list.length(joins1) |> should.equal(1)

  // Second diff: user:3 joined
  let joins2 = presence.diff_joins(diff2, "room:lobby")
  list.length(joins2) |> should.equal(1)
}

pub fn diff_accessors_return_empty_lists_for_unmentioned_topics_test() {
  let diff =
    presence.diff(
      joins: [
        #("room:lobby", [
          presence.PresenceEntry(
            pid: "socket-1",
            key: "user:1",
            meta: json.null(),
          ),
        ]),
      ],
      leaves: [],
    )

  presence.diff_joins(diff, "room:missing") |> should.equal([])
  presence.diff_leaves(diff, "room:missing") |> should.equal([])
}
