//// Real-node handle checks, called by beryl_presence_distributed_test.

import app_test_helper
import beryl
import beryl/error
import beryl/group
import beryl/overload
import beryl/presence
import beryl/pubsub
import beryl/snapshot
import beryl/transport
import beryl/wire
import gleam/erlang/atom
import gleam/erlang/process
import gleam/json
import gleam/list
import gleeunit/should

const topic = "room:foreign-handle"

/// Handles created on one node by the public constructors.
pub opaque type Fixture {
  Fixture(
    presence: presence.Presence,
    groups: group.Groups,
    sockets: beryl.Sockets,
    pubsub: pubsub.PubSub(String),
    subscriber: pubsub.Subscriber(String),
    owner: process.Pid,
    names: List(atom.Atom),
  )
}

@external(erlang, "beryl_pubsub_test_ffi", "registered_name")
fn registered_name(pid: process.Pid) -> atom.Atom

@external(erlang, "beryl_pubsub_test_ffi", "with_name_aliases")
fn with_name_aliases(
  foreign_names: List(atom.Atom),
  local_names: List(atom.Atom),
  action: fn() -> Nil,
) -> Nil

/// Keep linked fixture supervisors alive until the disposable peer stops.
pub fn start_fixture() -> Fixture {
  let ready = process.new_subject()
  let _owner =
    process.spawn_unlinked(fn() {
      let assert Ok(tracker) =
        presence.start(presence.default_config("foreign-handle"))
      let assert Ok(groups) = group.start()
      let assert Ok(sockets) =
        app_test_helper.start_app(
          beryl.config(wire.phoenix_codec()),
          init: app_test_helper.accepting_init,
          update: app_test_helper.accepting_update,
        )
      let assert Ok(bus) =
        pubsub.start(pubsub.config_with_scope("beryl_foreign_handle_test"))
      let subscriber = pubsub.subscriber(bus)
      pubsub.join(subscriber, topic) |> should.equal(Ok(Nil))
      presence.track(tracker, topic, "baseline", "baseline", json.null())
      |> should.be_ok
      group.create(groups, "baseline") |> should.equal(Ok(Nil))
      let assert Ok(presence_owner) =
        process.subject_owner(presence.subject(tracker))
      let assert Ok(group_owner) = process.subject_owner(group.subject(groups))
      let assert Ok(runtime_owner) = beryl.app_runtime_pid(sockets)
      process.send(
        ready,
        Fixture(tracker, groups, sockets, bus, subscriber, process.self(), [
          registered_name(presence_owner),
          registered_name(group_owner),
          registered_name(runtime_owner),
        ]),
      )
      process.sleep_forever()
    })
  let assert Ok(fixture) = process.receive(ready, 5000)
  fixture
}

/// Reject foreign reads and mutations even while matching local names exist.
pub fn reject_foreign(foreign: Fixture, local: Fixture) -> Nil {
  use <- with_name_aliases(foreign.names, local.names)
  presence.list(foreign.presence, topic) |> should.equal(Error(Nil))
  presence.get_by_key(foreign.presence, topic, "baseline")
  |> should.equal(Error(Nil))
  presence.count(foreign.presence, topic) |> should.equal(Error(Nil))
  presence.is_running(foreign.presence) |> should.be_false
  presence.queue_snapshot(foreign.presence)
  |> should.equal(Error(overload.Unavailable))
  presence.track(foreign.presence, topic, "intrusion", "intrusion", json.null())
  |> should.equal(
    Error(
      presence.TrackRequestFailed(overload.AdmissionRejected(
        overload.Unavailable,
      )),
    ),
  )
  presence.untrack_all(foreign.presence, "baseline")
  |> should.equal(Error(overload.AdmissionRejected(overload.Unavailable)))

  group.list_groups(foreign.groups)
  |> should.equal(Error(group.GroupCallFailed(error.CallUnavailable)))
  group.topics(foreign.groups, "baseline")
  |> should.equal(Error(group.GroupCallFailed(error.CallUnavailable)))
  group.create(foreign.groups, "intrusion")
  |> should.equal(Error(group.GroupCallFailed(error.CallUnavailable)))
  group.delete(foreign.groups, "baseline")
  |> should.equal(Error(group.GroupCallFailed(error.CallUnavailable)))

  snapshot.get(foreign.sockets)
  |> should.equal(Error(snapshot.RuntimeUnavailable))
  snapshot.queue(foreign.sockets)
  |> should.equal(Error(overload.Unavailable))
  beryl.app_runtime_pid(foreign.sockets) |> should.equal(Error(Nil))
  beryl.app_socket_factory_pid(foreign.sockets) |> should.equal(Error(Nil))
  transport.runtime_pid(foreign.sockets) |> should.equal(Error(Nil))
  transport.acquire_connection_slot(foreign.sockets, "127.0.0.1")
  |> should.equal(Error(Nil))
  beryl.broadcast(foreign.sockets, topic, "intrusion", json.null())
  |> should.equal(Error(overload.Unavailable))
  beryl.stop(foreign.sockets) |> should.equal(Error(beryl.NotRunning))

  pubsub.subscribers(foreign.pubsub, topic)
  |> should.equal(Error(pubsub.MembershipCallFailed(error.CallUnavailable)))
  pubsub.subscriber_count(foreign.pubsub, topic)
  |> should.equal(Error(pubsub.MembershipCallFailed(error.CallUnavailable)))
  pubsub.broadcast(foreign.pubsub, topic, "intrusion", "payload")
  |> should.equal(Error(pubsub.MembershipCallFailed(error.CallUnavailable)))
  pubsub.local_broadcast(foreign.pubsub, topic, "intrusion", "payload")
  |> should.equal(Error(pubsub.MembershipCallFailed(error.CallUnavailable)))
  pubsub.join(foreign.subscriber, "intrusion")
  |> should.equal(Error(pubsub.MembershipCallFailed(error.CallUnavailable)))
  pubsub.leave(foreign.subscriber, topic)
  |> should.equal(Error(pubsub.MembershipCallFailed(error.CallUnavailable)))
  let async_subscriber = pubsub.async_subscriber(foreign.pubsub)
  pubsub.join_async(async_subscriber, "intrusion")
  |> should.equal(Error(Nil))
  pubsub.leave_async(async_subscriber, topic) |> should.equal(Error(Nil))
  assert_unchanged(local)
}

/// Each origin's local handle and data still work after foreign operations.
pub fn assert_unchanged(fixture: Fixture) -> Nil {
  presence.count(fixture.presence, topic) |> should.equal(Ok(1))
  presence.get_by_key(fixture.presence, topic, "intrusion")
  |> should.equal(Ok([]))
  group.list_groups(fixture.groups) |> should.equal(Ok(["baseline"]))
  let assert Ok(stats) = snapshot.get(fixture.sockets)
  snapshot.connected_sockets(stats) |> should.equal(0)
  snapshot.active_topics(stats) |> should.equal(0)
  snapshot.queue(fixture.sockets) |> should.be_ok
  let assert Ok(members) = pubsub.subscribers(fixture.pubsub, topic)
  list.contains(members, fixture.owner) |> should.be_true
  pubsub.subscribers(fixture.pubsub, "intrusion") |> should.equal(Ok([]))
}
