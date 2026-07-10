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
  entry.session_id |> should.equal("socket-1")
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

  let ref = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  presence.untrack(p, ref)

  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(0)
}

pub fn presence_track_returns_ref_distinct_from_pid_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let ref = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  // The returned ref must be a server-generated handle, not the passed pid.
  ref |> should.not_equal("socket-1")
}

pub fn presence_track_yields_distinct_refs_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let ref1 = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let ref2 = presence.track(p, "room:lobby", "user:2", "socket-2", json.null())

  ref1 |> should.not_equal(ref2)
}

pub fn presence_untrack_removes_only_that_ref_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let ref1 = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ref2 = presence.track(p, "room:lobby", "user:2", "socket-2", json.null())

  // Untracking ref1 removes exactly that presence, leaving ref2's intact.
  presence.untrack(p, ref1)

  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(1)
  let assert [entry] = entries
  entry.session_id |> should.equal("socket-2")
}

pub fn presence_untrack_unknown_ref_is_noop_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  // An unknown/stale ref is a harmless no-op.
  presence.untrack(p, "does-not-exist")

  list.length(presence.list(p, "room:lobby")) |> should.equal(1)
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

pub fn presence_untrack_all_leaves_no_dangling_refs_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let ref1 = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ref2 =
    presence.track(p, "room:general", "user:1", "socket-1", json.null())

  presence.untrack_all(p, "socket-1")

  // A fresh track re-populates state.
  let _ = presence.track(p, "room:lobby", "user:2", "socket-2", json.null())
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)

  // Replaying a ref that untrack_all should have dropped must be a no-op and
  // must not disturb the surviving presence.
  presence.untrack(p, ref1)
  list.length(presence.list(p, "room:lobby")) |> should.equal(1)
  let assert [entry] = presence.list(p, "room:lobby")
  entry.session_id |> should.equal("socket-2")
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

pub fn diff_topics_deduplicates_topics_in_joins_and_leaves_test() {
  let diff =
    presence.diff(joins: [#("room:lobby", [])], leaves: [#("room:lobby", [])])

  presence.diff_topics(diff)
  |> should.equal(["room:lobby"])
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
      session_id: "socket-1",
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
  let ref =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("status", json.string("online"))]),
    )
  let assert Ok(_) = process.receive(diff_subject, 1000)

  presence.untrack(p, ref)

  let assert Ok(diff) = process.receive(diff_subject, 1000)
  presence.diff_topics(diff)
  |> should.equal(["room:lobby"])
  presence.diff_joins(diff, "room:lobby") |> should.equal([])
  presence.diff_leaves(diff, "room:lobby")
  |> should.equal([
    presence.PresenceEntry(
      session_id: "socket-1",
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
            session_id: "socket-1",
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
