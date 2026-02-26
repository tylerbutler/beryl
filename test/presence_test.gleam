import beryl/presence
import beryl/presence/state
import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn test_config(replica: String) -> presence.Config {
  presence.Config(
    pubsub: None,
    replica: replica,
    broadcast_interval_ms: 0,
    on_diff: None,
  )
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

pub fn presence_merge_remote_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  // Track locally
  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  // Create a remote state with a different entry
  let remote =
    state.new("node2")
    |> state.join("socket-2", "room:lobby", "user:2", json.null())

  // Merge remote state
  presence.merge_remote(p, remote)

  // Give the actor a moment to process the async merge
  // Use a synchronous call to ensure ordering
  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(2)
}

pub fn presence_empty_list_test() {
  let assert Ok(p) = presence.start(test_config("node1"))
  let entries = presence.list(p, "room:empty")
  list.length(entries) |> should.equal(0)
}

pub fn presence_default_config_test() {
  let config = presence.default_config("my-node")
  config.replica |> should.equal("my-node")
  config.broadcast_interval_ms |> should.equal(0)
  config.pubsub |> should.equal(None)
  config.on_diff |> should.equal(None)
}

// ── on_diff callback tests ──────────────────────────────────────────────────

pub fn on_diff_callback_receives_merge_diff_test() {
  // Set up a Subject to collect diffs from the callback
  let diff_subject = process.new_subject()

  let config =
    presence.Config(
      pubsub: None,
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: Some(fn(diff) { process.send(diff_subject, diff) }),
    )

  let assert Ok(p) = presence.start(config)

  // Track locally
  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  // Create a remote state and merge it
  let remote =
    state.new("node2")
    |> state.join("socket-2", "room:lobby", "user:2", json.null())

  presence.merge_remote(p, remote)

  // The merge is async (fire-and-forget), so use a synchronous list call
  // to ensure the merge message has been processed
  let _ = presence.list(p, "room:lobby")

  // Now the on_diff callback should have fired
  let assert Ok(diff) = process.receive(diff_subject, 1000)

  // The diff should contain user:2 as a join
  let assert Ok(joins) = dict.get(diff.joins, "room:lobby")
  list.length(joins) |> should.equal(1)
  dict.is_empty(diff.leaves) |> should.be_true
}

pub fn on_diff_callback_not_called_for_empty_diff_test() {
  let diff_subject = process.new_subject()

  let config =
    presence.Config(
      pubsub: None,
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: Some(fn(diff) { process.send(diff_subject, diff) }),
    )

  let assert Ok(p) = presence.start(config)

  // Merge an empty remote state (should produce an empty diff)
  let remote = state.new("node2")
  presence.merge_remote(p, remote)

  // Ensure the merge has been processed
  let _ = presence.list(p, "room:lobby")

  // Callback should NOT have been called for empty diff
  let result = process.receive(diff_subject, 100)
  should.be_error(result)
}

pub fn on_diff_callback_receives_all_rapid_diffs_test() {
  let diff_subject = process.new_subject()

  let config =
    presence.Config(
      pubsub: None,
      replica: "node1",
      broadcast_interval_ms: 0,
      on_diff: Some(fn(diff) { process.send(diff_subject, diff) }),
    )

  let assert Ok(p) = presence.start(config)

  // Rapidly merge multiple remote states
  let remote1 =
    state.new("node2")
    |> state.join("socket-2", "room:lobby", "user:2", json.null())

  let remote2 =
    state.new("node3")
    |> state.join("socket-3", "room:lobby", "user:3", json.null())

  presence.merge_remote(p, remote1)
  presence.merge_remote(p, remote2)

  // Ensure both merges have been processed
  let _ = presence.list(p, "room:lobby")

  // Both diffs should have been delivered (no overwrite)
  let assert Ok(diff1) = process.receive(diff_subject, 1000)
  let assert Ok(diff2) = process.receive(diff_subject, 1000)

  // First diff: user:2 joined
  let assert Ok(joins1) = dict.get(diff1.joins, "room:lobby")
  list.length(joins1) |> should.equal(1)

  // Second diff: user:3 joined
  let assert Ok(joins2) = dict.get(diff2.joins, "room:lobby")
  list.length(joins2) |> should.equal(1)
}
