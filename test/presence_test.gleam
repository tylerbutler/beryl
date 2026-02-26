import beryl/presence
import beryl/presence/state
import gleam/json
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn test_config(replica: String) -> presence.Config {
  presence.Config(pubsub: None, replica: replica, broadcast_interval_ms: 0)
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
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.string("meta1"),
    )
  let _ =
    presence.track(
      p,
      "room:lobby",
      "user:2",
      "socket-2",
      json.string("meta2"),
    )

  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(2)
}

pub fn presence_untrack_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  presence.untrack(p, "room:lobby", "user:1", "socket-1")

  let entries = presence.list(p, "room:lobby")
  list.length(entries) |> should.equal(0)
}

pub fn presence_untrack_all_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ =
    presence.track(p, "room:general", "user:1", "socket-1", json.null())

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

  let _ =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ =
    presence.track(p, "room:other", "user:2", "socket-2", json.null())

  list.length(presence.list(p, "room:lobby")) |> should.equal(1)
  list.length(presence.list(p, "room:other")) |> should.equal(1)
  list.length(presence.list(p, "room:empty")) |> should.equal(0)
}

pub fn presence_merge_remote_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  // Track locally
  let _ =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

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

pub fn presence_get_diff_no_prior_merge_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  // No merge has happened, so diff returns current state as all joins
  let #(joins, leaves) = presence.get_diff(p, "room:lobby")
  list.length(joins) |> should.equal(1)
  list.length(leaves) |> should.equal(0)
}

pub fn presence_default_config_test() {
  let config = presence.default_config("my-node")
  config.replica |> should.equal("my-node")
  config.broadcast_interval_ms |> should.equal(0)
  config.pubsub |> should.equal(None)
}
