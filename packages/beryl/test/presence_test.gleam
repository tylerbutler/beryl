import beryl/presence
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit
import gleeunit/should
import test_helpers

pub fn main() {
  gleeunit.main()
}

fn test_config(replica: String) -> presence.Config {
  presence.default_config(replica)
}

pub fn presence_start_test() {
  let #(p, spec) = presence.child_spec(test_config("node1"))
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  presence.list(p, "room:lobby") |> should.equal(Ok([]))
}

pub fn presence_handle_and_reads_survive_supervised_restart_test() {
  let #(p, spec) = presence.child_spec(test_config("node1"))
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  let _ref =
    presence.track(p, "room:lobby", "user:old", "socket-old", json.null())
  let assert Ok(old_pid) = process.subject_owner(presence.subject(p))

  process.kill(old_pid)
  test_helpers.wait_until(
    fn() {
      case process.subject_owner(presence.subject(p)) {
        Ok(pid) -> pid != old_pid
        Error(Nil) -> False
      }
    },
    2000,
    10,
  )

  presence.list(p, "room:lobby") |> should.equal(Ok([]))
  let _ref =
    presence.track(p, "room:lobby", "user:new", "socket-new", json.null())
  let assert Ok([entry]) = presence.list(p, "room:lobby")
  entry.key |> should.equal("user:new")
}

pub fn presence_track_and_list_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let meta = json.object([#("status", json.string("online"))])
  let _ref = presence.track(p, "room:lobby", "user:1", "socket-1", meta)

  let entries = presence_entries(p, "room:lobby")
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

  let entries = presence_entries(p, "room:lobby")
  list.length(entries) |> should.equal(2)
}

pub fn presence_untrack_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let ref = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  presence.untrack(p, ref)

  let entries = presence_entries(p, "room:lobby")
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

  let entries = presence_entries(p, "room:lobby")
  list.length(entries) |> should.equal(1)
  let assert [entry] = entries
  entry.session_id |> should.equal("socket-2")
}

pub fn presence_untrack_same_tuple_ref_preserves_other_ref_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let ref1 =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("device", json.string("desktop"))]),
    )
  let ref2 =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("device", json.string("mobile"))]),
    )

  presence_count(p, "room:lobby") |> should.equal(2)
  presence.untrack(p, ref1)

  let assert [remaining] = presence_entries(p, "room:lobby")
  let remaining_meta = json.to_string(remaining.meta)
  remaining_meta |> string.contains(ref2) |> should.be_true
  remaining_meta |> string.contains(ref1) |> should.be_false

  presence.untrack(p, ref1)
  presence_count(p, "room:lobby") |> should.equal(1)
  presence.untrack(p, ref2)
  presence_count(p, "room:lobby") |> should.equal(0)
}

pub fn presence_untrack_unknown_ref_is_noop_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  // An unknown/stale ref is a harmless no-op.
  presence.untrack(p, "does-not-exist")

  list.length(presence_entries(p, "room:lobby")) |> should.equal(1)
}

pub fn presence_update_replaces_one_ref_in_one_diff_test() {
  let diff_subject = process.new_subject()
  let config =
    presence.default_config("node1")
    |> presence.with_on_diff(fn(diff) { process.send(diff_subject, diff) })
  let assert Ok(p) = presence.start(config)

  let old_ref =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("device", json.string("desktop"))]),
    )
  let other_ref =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("device", json.string("mobile"))]),
    )
  let assert Ok(_) = process.receive(diff_subject, 1000)
  let assert Ok(_) = process.receive(diff_subject, 1000)

  let assert Ok(new_ref) =
    presence.update(
      p,
      old_ref,
      json.object([#("device", json.string("tablet"))]),
    )
  new_ref |> should.not_equal(old_ref)
  new_ref |> should.not_equal(other_ref)

  let assert Ok(diff) = process.receive(diff_subject, 1000)
  process.receive(diff_subject, 0) |> should.be_error
  let assert [joined] = presence.diff_joins(diff, "room:lobby")
  let assert [left] = presence.diff_leaves(diff, "room:lobby")
  json.to_string(joined.meta) |> string.contains("tablet") |> should.be_true
  json.to_string(joined.meta) |> string.contains(new_ref) |> should.be_true
  json.to_string(left.meta) |> string.contains("desktop") |> should.be_true
  json.to_string(left.meta) |> string.contains(old_ref) |> should.be_true

  presence_count(p, "room:lobby") |> should.equal(2)
  let metas =
    presence_metas(p, "room:lobby", "user:1")
    |> list.map(fn(entry) { json.to_string(entry.1) })
    |> string.join(",")
  metas |> string.contains("tablet") |> should.be_true
  metas |> string.contains("mobile") |> should.be_true
  metas |> string.contains("desktop") |> should.be_false
}

pub fn presence_update_unknown_or_stale_ref_is_error_test() {
  let diff_subject = process.new_subject()
  let config =
    presence.default_config("node1")
    |> presence.with_on_diff(fn(diff) { process.send(diff_subject, diff) })
  let assert Ok(p) = presence.start(config)
  let ref = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let assert Ok(_) = process.receive(diff_subject, 1000)

  presence.update(p, "does-not-exist", json.null())
  |> should.equal(Error(presence.UnknownRef))
  process.receive(diff_subject, 0) |> should.be_error

  let assert Ok(new_ref) = presence.update(p, ref, json.null())
  let assert Ok(_) = process.receive(diff_subject, 1000)
  presence.update(p, ref, json.null())
  |> should.equal(Error(presence.UnknownRef))
  presence.untrack(p, new_ref)
}

pub fn presence_update_rejects_runtime_owned_ref_test() {
  let assert Ok(p) = presence.start(test_config("node1"))
  let reply = process.new_subject()
  presence.track_async(
    p,
    "room:lobby",
    "user:1",
    "socket-1",
    json.object([#("status", json.string("online"))]),
    None,
    "test",
    1,
    reply,
  )
  let assert Ok(presence.MutationAck(
    outcome: presence.Tracked(runtime_ref, _),
    ..,
  )) = process.receive(reply, 1000)

  presence.update(p, runtime_ref, json.null())
  |> should.equal(Error(presence.UnknownRef))
  let assert [entry] = presence_entries(p, "room:lobby")
  json.to_string(entry.meta) |> string.contains("online") |> should.be_true
}

pub fn presence_untrack_all_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p, "room:general", "user:1", "socket-1", json.null())

  // Both topics have entries from socket-1
  list.length(presence_entries(p, "room:lobby")) |> should.equal(1)
  list.length(presence_entries(p, "room:general")) |> should.equal(1)

  // Untrack all for socket-1
  presence.untrack_all(p, "socket-1")

  list.length(presence_entries(p, "room:lobby")) |> should.equal(0)
  list.length(presence_entries(p, "room:general")) |> should.equal(0)
}

pub fn presence_untrack_all_leaves_no_dangling_refs_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let ref1 = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ref2 =
    presence.track(p, "room:general", "user:1", "socket-1", json.null())

  presence.untrack_all(p, "socket-1")

  // A fresh track re-populates state.
  let _ = presence.track(p, "room:lobby", "user:2", "socket-2", json.null())
  list.length(presence_entries(p, "room:lobby")) |> should.equal(1)

  // Replaying a ref that untrack_all should have dropped must be a no-op and
  // must not disturb the surviving presence.
  presence.untrack(p, ref1)
  list.length(presence_entries(p, "room:lobby")) |> should.equal(1)
  let assert [entry] = presence_entries(p, "room:lobby")
  entry.session_id |> should.equal("socket-2")
}

pub fn presence_get_by_key_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let meta1 = json.object([#("device", json.string("desktop"))])
  let meta2 = json.object([#("device", json.string("mobile"))])
  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", meta1)
  let _ = presence.track(p, "room:lobby", "user:1", "socket-2", meta2)

  let entries = presence_metas(p, "room:lobby", "user:1")
  list.length(entries) |> should.equal(2)
}

pub fn presence_different_topics_isolated_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p, "room:other", "user:2", "socket-2", json.null())

  list.length(presence_entries(p, "room:lobby")) |> should.equal(1)
  list.length(presence_entries(p, "room:other")) |> should.equal(1)
  list.length(presence_entries(p, "room:empty")) |> should.equal(0)
}

pub fn presence_empty_list_test() {
  let assert Ok(p) = presence.start(test_config("node1"))
  let entries = presence_entries(p, "room:empty")
  list.length(entries) |> should.equal(0)
}

// ── count ────────────────────────────────────────────────────────────────

pub fn presence_count_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p, "room:lobby", "user:2", "socket-2", json.null())

  presence_count(p, "room:lobby") |> should.equal(2)
}

pub fn presence_count_matches_list_length_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p, "room:lobby", "user:2", "socket-2", json.null())
  let _ = presence.track(p, "room:lobby", "user:3", "socket-3", json.null())

  presence_count(p, "room:lobby")
  |> should.equal(list.length(presence_entries(p, "room:lobby")))
}

pub fn presence_count_missing_topic_is_zero_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  presence_count(p, "room:never-touched") |> should.equal(0)
}

pub fn presence_count_empty_after_untrack_all_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  presence.untrack_all(p, "socket-1")

  presence_count(p, "room:lobby") |> should.equal(0)
}

// ── get_by_key on a missing topic ───────────────────────────────────────────

pub fn presence_get_by_key_missing_topic_returns_empty_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  presence_metas(p, "room:never-touched", "user:1")
  |> should.equal([])
}

// ── track/untrack/untrack_all read-after-write consistency ─────────────────
//
// `list`, `get_by_key`, and `count` read a materialized snapshot from an
// ETS table, not the actor's CRDT directly. These calls check for immediate
// (not eventual) consistency: no `wait_until` polling, proving `track` only
// replies after its read-model snapshot has already been published.

pub fn track_is_immediately_visible_to_all_readers_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let meta = json.object([#("status", json.string("online"))])
  let _ref = presence.track(p, "room:lobby", "user:1", "socket-1", meta)

  presence_count(p, "room:lobby") |> should.equal(1)
  list.length(presence_entries(p, "room:lobby")) |> should.equal(1)
  list.length(presence_metas(p, "room:lobby", "user:1")) |> should.equal(1)
}

pub fn untrack_is_immediately_visible_to_all_readers_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let ref = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  presence.untrack(p, ref)

  presence_count(p, "room:lobby") |> should.equal(0)
  presence_entries(p, "room:lobby") |> should.equal([])
  presence_metas(p, "room:lobby", "user:1") |> should.equal([])
}

pub fn untrack_all_is_immediately_visible_across_topics_test() {
  let assert Ok(p) = presence.start(test_config("node1"))

  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p, "room:general", "user:1", "socket-1", json.null())

  presence.untrack_all(p, "socket-1")

  presence_count(p, "room:lobby") |> should.equal(0)
  presence_count(p, "room:general") |> should.equal(0)
}

pub fn presence_default_config_test() {
  let assert Ok(p) = presence.start(presence.default_config("my-node"))
  let _ = presence.track(p, "room:default", "user:1", "socket-1", json.null())

  presence_entries(p, "room:default")
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
  let assert [entry] = presence.diff_joins(diff, "room:lobby")
  entry.session_id |> should.equal("socket-1")
  entry.key |> should.equal("user:1")
  // The tracked meta carries the original fields plus the injected phx_ref
  let encoded_meta = json.to_string(entry.meta)
  encoded_meta
  |> string.contains("\"status\":\"online\"")
  |> should.be_true
  encoded_meta
  |> string.contains("phx_ref")
  |> should.be_true
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
  let assert [entry] = presence.diff_leaves(diff, "room:lobby")
  entry.session_id |> should.equal("socket-1")
  entry.key |> should.equal("user:1")
  // The leave carries the same meta the track stored, including its phx_ref
  let encoded_meta = json.to_string(entry.meta)
  encoded_meta
  |> string.contains("\"status\":\"online\"")
  |> should.be_true
  encoded_meta
  |> string.contains("phx_ref")
  |> should.be_true
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

// ── read model lifetime: reads fail explicitly after the actor dies ────────
//
// `list`, `get_by_key`, and `count` read an ETS table owned by the presence
// actor process; the table is destroyed automatically when that process
// stops. These checks prove a dead actor's reads panic loudly instead of
// silently falling back to an empty/default result, which would be
// indistinguishable from a topic that simply has no presences.

/// Run `op` in an unlinked process and confirm it crashes (any reason other
/// than a normal exit) rather than returning normally. Unlinked + monitored
/// so the panic inside `op` cannot bring down the test process itself.
fn assert_crashes(op: fn() -> Nil) -> Nil {
  let pid = process.spawn_unlinked(op)
  let mon = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(mon, fn(down) { down })

  case process.selector_receive(selector, 1000) {
    Ok(process.ProcessDown(reason: process.Normal, ..)) -> should.fail()
    Ok(process.ProcessDown(..)) -> Nil
    Ok(process.PortDown(..)) -> should.fail()
    Error(Nil) -> should.fail()
  }
}

pub fn list_fails_after_presence_terminated_test() {
  let assert Ok(p) = presence.start(test_config("node1"))
  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  test_helpers.kill_presence(p)

  assert_crashes(fn() {
    let _ = presence_entries(p, "room:lobby")
    Nil
  })
}

pub fn get_by_key_fails_after_presence_terminated_test() {
  let assert Ok(p) = presence.start(test_config("node1"))
  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  test_helpers.kill_presence(p)

  assert_crashes(fn() {
    let _ = presence_metas(p, "room:lobby", "user:1")
    Nil
  })
}

pub fn count_fails_after_presence_terminated_test() {
  let assert Ok(p) = presence.start(test_config("node1"))
  let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())

  test_helpers.kill_presence(p)

  assert_crashes(fn() { presence_count(p, "room:lobby") |> should.equal(0) })
}

pub fn count_fails_after_presence_terminated_even_for_untouched_topic_test() {
  // A topic that was never tracked reads as count 0 while the actor is
  // alive (see `presence_count_missing_topic_is_zero_test`); once the
  // actor is gone, `count` must still fail explicitly rather than reusing
  // that same "0" default, since the two situations are not the same.
  let assert Ok(p) = presence.start(test_config("node1"))

  test_helpers.kill_presence(p)

  assert_crashes(fn() {
    presence_count(p, "room:never-touched") |> should.equal(0)
  })
}

pub fn configured_call_timeout_is_used_test() {
  let config =
    presence.default_config("node1")
    |> presence.with_call_timeout(20)
  let #(p, _spec) = presence.child_spec(config)

  assert_crashes(fn() {
    let _ = presence.track(p, "room:lobby", "user:1", "socket-1", json.null())
    Nil
  })
  assert_crashes(fn() {
    let _ = presence.update(p, "missing", json.null())
    Nil
  })
}

// ── multiple presence actors: independent, unnamed read tables ─────────────
//
// The read-model ETS table is created unnamed (no `named_table`) so
// concurrent actor starts never collide on a shared table name. These
// checks prove that in practice: several presence actors' reads stay fully
// isolated from one another, and terminating one actor's table has no
// effect on the others.

pub fn multiple_presence_actors_have_independent_read_tables_test() {
  let assert Ok(p1) = presence.start(test_config("node1"))
  let assert Ok(p2) = presence.start(test_config("node2"))
  let assert Ok(p3) = presence.start(test_config("node3"))

  let _ = presence.track(p1, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p2, "room:lobby", "user:2", "socket-2", json.null())
  let _ = presence.track(p2, "room:lobby", "user:3", "socket-3", json.null())

  // p3 never tracked anything in "room:lobby"; each actor's read model
  // reflects only what was tracked on it, never a peer's entries.
  presence_count(p1, "room:lobby") |> should.equal(1)
  presence_count(p2, "room:lobby") |> should.equal(2)
  presence_count(p3, "room:lobby") |> should.equal(0)
}

pub fn killing_one_presence_actor_does_not_affect_others_test() {
  let assert Ok(p1) = presence.start(test_config("node1"))
  let assert Ok(p2) = presence.start(test_config("node2"))

  let _ = presence.track(p1, "room:lobby", "user:1", "socket-1", json.null())
  let _ = presence.track(p2, "room:lobby", "user:2", "socket-2", json.null())

  test_helpers.kill_presence(p1)

  // p1's table is gone, but p2's is a separate (unnamed) table: its reads
  // keep working exactly as before, untouched by p1's death.
  presence_count(p2, "room:lobby") |> should.equal(1)
  list.length(presence_entries(p2, "room:lobby")) |> should.equal(1)

  assert_crashes(fn() {
    let _ = presence_entries(p1, "room:lobby")
    Nil
  })
}

fn presence_entries(
  tracker: presence.Presence,
  topic: String,
) -> List(presence.PresenceEntry) {
  let assert Ok(entries) = presence.list(tracker, topic)
  entries
}

fn presence_count(tracker: presence.Presence, topic: String) -> Int {
  let assert Ok(count) = presence.count(tracker, topic)
  count
}

fn presence_metas(
  tracker: presence.Presence,
  topic: String,
  key: String,
) -> List(#(String, json.Json)) {
  let assert Ok(metas) = presence.get_by_key(tracker, topic, key)
  metas
}
