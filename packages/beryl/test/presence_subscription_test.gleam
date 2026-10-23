import beryl/presence
import beryl/pubsub
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import test_helper

fn start() -> presence.Presence {
  let assert Ok(handle) = presence.start(presence.default_config("observer"))
  handle
}

fn start_distributed(
  pubsub_instance: pubsub.PubSub(presence.SyncPayload),
  replica: String,
) -> presence.Presence {
  let assert Ok(handle) =
    presence.start(
      presence.default_config(replica)
      |> presence.with_pubsub(pubsub_instance)
      |> presence.with_broadcast_interval(25),
    )
  handle
}

fn stop(handle: presence.Presence) -> Nil {
  let assert Ok(owner) = process.subject_owner(presence.subject(handle))
  process.unlink(owner)
  process.kill(owner)
}

fn subscribe(
  handle: presence.Presence,
) -> #(
  presence.Subscription,
  process.Subject(presence.Delivery),
  process.Subject(presence.ObservationFailure),
) {
  let events = process.new_subject()
  let failures = process.new_subject()
  let assert Ok(subscription) =
    presence.subscribe(
      handle,
      "socket",
      "room:a",
      process.self(),
      events,
      failures,
    )
  #(subscription, events, failures)
}

fn receive_event(
  events: process.Subject(presence.Delivery),
) -> presence.Delivery {
  let assert Ok(delivery) = process.receive(events, 1000)
  delivery
}

pub fn subscription_snapshot_and_later_changes_have_no_gap_test() -> Nil {
  let handle = start()
  let _before = presence.track(handle, "room:a", "before", "s1", json.null())
  let #(subscription, events, failures) = subscribe(handle)
  let _after = presence.track(handle, "room:a", "after", "s2", json.null())
  case receive_event(events) {
    presence.Delivery(0, presence.Snapshot([entry])) -> {
      entry.key |> should.equal("before")
      process.receive(events, 0) |> should.be_error
      presence.acknowledge(subscription, 0)
      let assert presence.Delivery(1, presence.Changed([entry], [])) =
        receive_event(events)
      entry.key |> should.equal("after")
    }
    presence.Delivery(0, presence.Snapshot([first, second])) -> {
      [first.key, second.key]
      |> list.sort(string.compare)
      |> should.equal(["after", "before"])
      presence.acknowledge(subscription, 0)
      process.receive(events, 50) |> should.be_error
    }
    presence.Delivery(0, presence.Snapshot([]))
    | presence.Delivery(0, presence.Snapshot([_, _, _, ..]))
    | presence.Delivery(0, presence.Changed(_, _))
    | presence.Delivery(_, _) -> should.fail()
  }
  process.receive(failures, 0) |> should.be_error
  presence.unsubscribe(subscription)
}

pub fn subscription_updates_are_one_change_and_credit_is_single_use_test() -> Nil {
  let handle = start()
  let assert Ok(ref) =
    presence.track(handle, "room:a", "alice", "s1", json.object([]))
  let #(subscription, events, _) = subscribe(handle)
  let assert presence.Delivery(0, presence.Snapshot([_])) =
    receive_event(events)
  let assert Ok(ref) =
    presence.update(
      handle,
      ref,
      json.object([#("status", json.string("away"))]),
    )
  let assert Ok(Nil) = presence.untrack(handle, ref)
  presence.acknowledge(subscription, 0)
  let assert presence.Delivery(1, presence.Changed([joined], [left])) =
    receive_event(events)
  joined.key |> should.equal(left.key)
  { json.to_string(joined.meta) == json.to_string(left.meta) }
  |> should.be_false
  presence.acknowledge(subscription, 0)
  process.receive(events, 50) |> should.be_error
  presence.acknowledge(subscription, 1)
  let assert presence.Delivery(2, presence.Changed([], [_])) =
    receive_event(events)
  presence.unsubscribe(subscription)
}

pub fn subscription_is_topic_scoped_and_unsubscribe_stops_delivery_test() -> Nil {
  let handle = start()
  let #(subscription, events, _) = subscribe(handle)
  let assert presence.Delivery(0, presence.Snapshot([])) = receive_event(events)
  presence.acknowledge(subscription, 0)
  let _ref = presence.track(handle, "room:b", "bob", "s1", json.null())
  process.receive(events, 50) |> should.be_error
  presence.unsubscribe(subscription)
  presence.unsubscribe(subscription)
  let _ref = presence.track(handle, "room:a", "alice", "s2", json.null())
  process.receive(events, 50) |> should.be_error
}

pub fn subscription_overflow_is_explicit_and_does_not_stop_presence_test() -> Nil {
  let handle = start()
  let #(subscription, events, failures) = subscribe(handle)
  let assert presence.Delivery(0, presence.Snapshot([])) = receive_event(events)
  list.repeat(Nil, 64)
  |> list.each(fn(_) {
    let _ref = presence.track(handle, "room:a", "alice", "s1", json.null())
    Nil
  })
  process.receive(failures, 0) |> should.be_error
  let _ref = presence.track(handle, "room:a", "alice", "s1", json.null())
  let assert Ok(presence.ObservationFailure(
    reason: presence.ObserverOverflow,
    ..,
  )) = process.receive(failures, 1000)
  presence.count(handle, "room:a") |> should.equal(Ok(65))
  presence.acknowledge(subscription, 0)
  process.receive(events, 50) |> should.be_error
  presence.unsubscribe(subscription)
}

pub fn subscriber_death_removes_the_actor_monitor_test() -> Nil {
  let handle = start()
  let assert Ok(owner) = process.subject_owner(presence.subject(handle))
  let worker = process.spawn_unlinked(fn() { process.sleep_forever() })
  let events = process.new_subject()
  let assert Ok(subscription) =
    presence.subscribe(
      handle,
      "s",
      "room:a",
      worker,
      events,
      process.new_subject(),
    )
  let _snapshot = receive_event(events)
  test_helper.monitor_count(owner) |> should.equal(1)
  process.kill(worker)
  test_helper.wait_until(
    fn() { test_helper.monitor_count(owner) == 0 },
    1000,
    10,
  )
  let _ref = presence.track(handle, "room:a", "alice", "s", json.null())
  process.receive(events, 50) |> should.be_error
  presence.unsubscribe(subscription)
}

pub fn remote_replacement_events_follow_committed_state_test() -> Nil {
  let pubsub = pubsub.start(pubsub.config_with_scope("observer_remote_prune"))
  let handle = start_distributed(pubsub, "observer")
  let old = start_distributed(pubsub, "peer")
  let assert Ok(_) = presence.track(old, "room:a", "alice", "old", json.null())
  test_helper.wait_until(
    fn() { presence.count(handle, "room:a") == Ok(1) },
    2000,
    10,
  )
  let #(subscription, events, _) = subscribe(handle)
  let assert presence.Delivery(0, presence.Snapshot([entry])) =
    receive_event(events)
  entry.session_id |> should.equal("old")
  presence.acknowledge(subscription, 0)
  stop(old)
  let assert presence.Delivery(1, presence.Changed([], [left])) =
    receive_event(events)
  left.session_id |> should.equal("old")
  presence.acknowledge(subscription, 1)
  let replacement = start_distributed(pubsub, "peer")
  let assert Ok(_) =
    presence.track(replacement, "room:a", "alice", "new", json.null())
  let assert presence.Delivery(2, presence.Changed([joined], [])) =
    receive_event(events)
  joined.session_id |> should.equal("new")
  presence.acknowledge(subscription, 2)
  test_helper.wait_until(
    fn() { presence.count(handle, "room:a") == Ok(1) },
    2000,
    10,
  )
  presence.unsubscribe(subscription)
  stop(replacement)
}

pub fn callback_failure_does_not_hide_committed_remote_change_test() -> Nil {
  let pubsub = pubsub.start(pubsub.config_with_scope("observer_failed_remote"))
  let assert Ok(handle) =
    presence.start(
      presence.default_config("observer")
      |> presence.with_pubsub(pubsub)
      |> presence.with_broadcast_interval(0)
      |> presence.with_on_diff(fn(diff) {
        case presence.diff_joins(diff, "room:a") {
          [] -> Nil
          _ -> panic as "reject remote change"
        }
      }),
    )
  let #(subscription, events, _) = subscribe(handle)
  let assert presence.Delivery(0, presence.Snapshot([])) = receive_event(events)
  presence.acknowledge(subscription, 0)
  let remote = start_distributed(pubsub, "peer")
  let assert Ok(_) = presence.track(remote, "room:a", "alice", "s", json.null())
  let assert presence.Delivery(1, presence.Changed([entry], [])) =
    receive_event(events)
  entry.key |> should.equal("alice")
  presence.list(handle, "room:a")
  |> result.map(list.length)
  |> should.equal(Ok(1))
  presence.unsubscribe(subscription)
  stop(remote)
}

pub fn retired_subscription_credit_cannot_release_a_new_stream_test() -> Nil {
  let handle = start()
  let #(old, old_events, _) = subscribe(handle)
  let _old_snapshot = receive_event(old_events)
  presence.unsubscribe(old)
  let #(current, events, _) = subscribe(handle)
  let assert presence.Delivery(0, presence.Snapshot([])) = receive_event(events)
  let _ref = presence.track(handle, "room:a", "alice", "s", json.null())
  presence.acknowledge(old, 0)
  presence.unsubscribe(old)
  process.receive(events, 50) |> should.be_error
  presence.acknowledge(current, 0)
  let assert presence.Delivery(1, presence.Changed([_], [])) =
    receive_event(events)
  presence.unsubscribe(current)
}

pub fn source_exit_during_subscription_is_safe_to_clean_up_test() -> Nil {
  let handle = start()
  let #(subscription, events, _) = subscribe(handle)
  let _snapshot = receive_event(events)
  test_helper.kill_presence(handle)
  presence.acknowledge(subscription, 0)
  presence.unsubscribe(subscription)
  let events = process.new_subject()
  presence.subscribe(
    handle,
    "s",
    "room:a",
    process.self(),
    events,
    process.new_subject(),
  )
  |> should.be_error
}
