//// Distributed broadcast for app-side dispatch: a `Broadcast` effect on one
//// runtime reaches a topic's subscribers on another runtime sharing the same
//// PubSub scope, and a `BroadcastFrom` effect excludes the sending socket
//// while still fanning out locally and across runtimes.

import app_test_helper
import beryl
import beryl/overload
import beryl/pubsub
import beryl/snapshot
import beryl/socket.{AcceptJoin, Broadcast, BroadcastFrom, Join, Message, Next}
import beryl/transport
import beryl/wire
import gleam/erlang/atom
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import test_helper
import unitest

@external(erlang, "beryl_pubsub_test_ffi", "kill_scope")
fn kill_scope(scope: atom.Atom) -> process.Pid

@external(erlang, "beryl_pubsub_test_ffi", "recovered")
fn recovered(
  scope: atom.Atom,
  old_pid: process.Pid,
  topic: String,
  count: Int,
) -> Bool

@external(erlang, "beryl_pubsub_test_ffi", "during_outage")
fn during_outage(scope: atom.Atom, operation: fn() -> Nil) -> process.Pid

@external(erlang, "beryl_pubsub_test_ffi", "with_suspended_registry")
fn with_suspended_registry(
  scope: atom.Atom,
  operation: fn(process.Pid) -> Nil,
) -> Nil

@external(erlang, "beryl_pubsub_test_ffi", "membership_intent_size")
fn membership_intent_size(owner: process.Pid) -> Int

@external(erlang, "beryl_pubsub_test_ffi", "kill_registry")
fn kill_registry(scope: atom.Atom) -> Nil

fn heartbeat(sockets: beryl.Sockets, frames: process.Subject(String)) -> Nil {
  app_test_helper.route(
    sockets,
    "observer",
    "[null,\"heartbeat\",\"phoenix\",\"heartbeat\",{}]",
  )
  process.receive(frames, 200)
  |> should.equal(Ok(
    "[null,\"heartbeat\",\"phoenix\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  ))
}

fn join_topic(
  sockets: beryl.Sockets,
  frames: process.Subject(String),
  topic: String,
) -> Nil {
  app_test_helper.join_ok(sockets, frames, "newcomer", topic, "jr-new", "r-new")
}

fn leave_topic(
  sockets: beryl.Sockets,
  frames: process.Subject(String),
  topic: String,
) -> Nil {
  app_test_helper.route(
    sockets,
    "newcomer",
    "[\"jr-new\",\"r-leave\",\"" <> topic <> "\",\"phx_leave\",{}]",
  )
  app_test_helper.recv(frames)
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  app_test_helper.recv(frames)
  |> string.contains("\"phx_close\"")
  |> should.be_true
}

pub fn stalled_registry_does_not_block_router_traffic_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = "app_bcast_stalled_registry"
  let sockets = start_runtime(scope)
  let observer = join_lobby(sockets, "observer", "jr-observer")
  let newcomer = app_test_helper.connect(sockets, "newcomer")
  let router = app_test_helper.runtime_pid(sockets)
  let instance = pubsub.start(pubsub.config_with_scope(scope))
  test_helper.wait_until(
    fn() { pubsub.subscriber_count(instance, "room:lobby") == 1 },
    2000,
    5,
  )
  with_suspended_registry(atom.create(scope), fn(_registry) {
    join_topic(sockets, newcomer, "room:new")
    join_topic(sockets, newcomer, "room:gone")
    leave_topic(sockets, newcomer, "room:gone")
    test_helper.wait_until(
      fn() {
        case snapshot.get(sockets) {
          Ok(value) -> snapshot.active_topics(value) == 2
          Error(_) -> False
        }
      },
      2000,
      5,
    )
    heartbeat(sockets, observer)
    beryl.broadcast(sockets, "room:lobby", "still-local", json.object([]))
    |> should.equal(Ok(Nil))
    app_test_helper.recv(observer)
    |> string.contains("still-local")
    |> should.be_true
    transport.runtime_pid(sockets) |> should.equal(Ok(router))
  })
  test_helper.wait_until(
    fn() {
      pubsub.subscriber_count(instance, "room:new") == 1
      && pubsub.subscriber_count(instance, "room:gone") == 0
    },
    2000,
    5,
  )
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn stalled_registry_coalesces_membership_churn_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = "app_bcast_coalesced_registry"
  let instance = pubsub.start(pubsub.config_with_scope(scope))
  let assert Ok(limits) = overload.limits(items: 8, bytes: 8192)
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_pubsub(instance)
        |> beryl.with_router_queue_limits(limits)
        |> beryl.with_max_joined_topics_per_socket(1),
      init: app_test_helper.accepting_init,
      update: app_test_helper.accepting_update,
    )
  let observer = join_lobby(sockets, "observer", "jr-observer")
  let newcomer = app_test_helper.connect(sockets, "newcomer")
  let router = app_test_helper.runtime_pid(sockets)
  test_helper.wait_until(
    fn() { pubsub.subscriber_count(instance, "room:lobby") == 1 },
    2000,
    5,
  )
  with_suspended_registry(atom.create(scope), fn(registry) {
    list.each(list.repeat(Nil, 2), fn(_) {
      list.each(list.repeat(Nil, 100), fn(_) {
        join_topic(sockets, newcomer, "room:churn")
        leave_topic(sockets, newcomer, "room:churn")
      })
      // A snapshot turn is behind every index transition from this socket.
      let assert Ok(value) = snapshot.get(sockets)
      snapshot.active_topics(value) |> should.equal(1)
      { test_helper.mailbox_length(registry) <= 2 } |> should.be_true
      membership_intent_size(router) |> should.equal(1)
      heartbeat(sockets, observer)
    })
    join_topic(sockets, newcomer, "room:final")
  })
  test_helper.wait_until(
    fn() {
      pubsub.subscriber_count(instance, "room:final") == 1
      && pubsub.subscriber_count(instance, "room:churn") == 0
    },
    2000,
    5,
  )
  with_suspended_registry(atom.create(scope), fn(_registry) {
    beryl.stop(sockets) |> should.equal(Ok(Nil))
    membership_intent_size(router) |> should.equal(0)
  })
  test_helper.wait_until(
    fn() { pubsub.subscriber_count(instance, "room:final") == 0 },
    2000,
    5,
  )
}

pub fn joins_and_leaves_during_pg_outage_preserve_live_sockets_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = "app_bcast_live_recovery"
  let sockets = start_runtime(scope)
  let other = start_runtime(scope)
  let observer = join_lobby(sockets, "observer", "jr-observer")
  let remote = join_lobby(other, "remote", "jr-remote")
  let newcomer = app_test_helper.connect(sockets, "newcomer")
  join_topic(sockets, newcomer, "room:gone")
  let instance = pubsub.start(pubsub.config_with_scope(scope))
  test_helper.wait_until(
    fn() {
      pubsub.subscriber_count(instance, "room:lobby") == 2
      && pubsub.subscriber_count(instance, "room:gone") == 1
    },
    2000,
    5,
  )
  let router = app_test_helper.runtime_pid(sockets)
  let old_pid =
    during_outage(atom.create(scope), fn() {
      join_topic(sockets, newcomer, "room:new")
      leave_topic(sockets, newcomer, "room:gone")
      join_topic(sockets, newcomer, "room:cycling")
      leave_topic(sockets, newcomer, "room:cycling")
      join_topic(sockets, newcomer, "room:cycling")
      test_helper.wait_until(
        fn() {
          case snapshot.get(sockets) {
            Ok(value) -> snapshot.active_topics(value) == 3
            Error(_) -> False
          }
        },
        2000,
        5,
      )
      heartbeat(sockets, observer)
      transport.runtime_pid(sockets) |> should.equal(Ok(router))
    })
  test_helper.wait_until(
    fn() {
      recovered(atom.create(scope), old_pid, "room:lobby", 2)
      && pubsub.subscriber_count(instance, "room:new") == 1
      && pubsub.subscriber_count(instance, "room:cycling") == 1
      && pubsub.subscriber_count(instance, "room:gone") == 0
    },
    5000,
    5,
  )
  beryl.broadcast(sockets, "room:lobby", "recovered", json.object([]))
  |> should.equal(Ok(Nil))
  app_test_helper.recv(observer)
  |> string.contains("recovered")
  |> should.be_true
  app_test_helper.recv(remote) |> string.contains("recovered") |> should.be_true
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  beryl.stop(other) |> should.equal(Ok(Nil))
}

pub fn registry_loss_preserves_local_router_delivery_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = "app_bcast_registry_loss"
  let sockets = start_runtime(scope)
  let observer = join_lobby(sockets, "observer", "jr-observer")
  let router = app_test_helper.runtime_pid(sockets)
  kill_registry(atom.create(scope))
  let newcomer = app_test_helper.connect(sockets, "newcomer")
  join_topic(sockets, newcomer, "room:new")
  leave_topic(sockets, newcomer, "room:new")
  beryl.broadcast(sockets, "room:lobby", "still-local", json.object([]))
  |> should.equal(Ok(Nil))
  app_test_helper.recv(observer)
  |> string.contains("still-local")
  |> should.be_true
  beryl.app_dispatch(sockets).broadcast_local(
    "room:lobby",
    "still-local-only",
    json.object([]),
  )
  |> should.equal(Ok(Nil))
  app_test_helper.recv(observer)
  |> string.contains("still-local-only")
  |> should.be_true
  heartbeat(sockets, observer)
  transport.runtime_pid(sockets) |> should.equal(Ok(router))
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn pubsub_scope_recovery_preserves_runtime_broadcasts_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = "app_bcast_scope_recovery"
  let node_a = start_runtime(scope)
  let node_b = start_runtime(scope)
  let sender = join_lobby(node_a, "recovery-sender", "jr-a")
  let observer = join_lobby(node_b, "recovery-observer", "jr-b")
  let instance = pubsub.start(pubsub.config_with_scope(scope))
  test_helper.wait_until(
    fn() { pubsub.subscriber_count(instance, "room:lobby") == 2 },
    5000,
    10,
  )
  let old_pid = kill_scope(atom.create(scope))
  test_helper.wait_until(
    fn() { recovered(atom.create(scope), old_pid, "room:lobby", 2) },
    5000,
    10,
  )
  let newcomer = join_lobby(node_b, "recovery-newcomer", "jr-new")
  app_test_helper.push(node_a, "recovery-sender", "room:lobby", "cast", "r-2")
  app_test_helper.recv(sender) |> string.contains("shout") |> should.be_true
  app_test_helper.recv(observer) |> string.contains("shout") |> should.be_true
  app_test_helper.recv(newcomer) |> string.contains("shout") |> should.be_true
  app_test_helper.recv_none(sender)
  app_test_helper.recv_none(observer)
  app_test_helper.recv_none(newcomer)
  beryl.stop(node_a) |> should.equal(Ok(Nil))
  beryl.stop(node_b) |> should.equal(Ok(Nil))
}

fn start_runtime(scope: String) -> beryl.Sockets {
  let started_pubsub = pubsub.start(pubsub.config_with_scope(scope))
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(started_pubsub),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, event) {
        case event {
          Join(_, _, ref) -> Next(model, [AcceptJoin(ref, None)])
          Message(topic, "cast", _payload, _ref) ->
            Next(model, [Broadcast(topic, "shout", json.object([]))])
          Message(topic, "cast_others", _payload, _ref) ->
            Next(model, [BroadcastFrom(topic, "shout", json.object([]))])
          Message(..)
          | socket.Binary(..)
          | socket.Closed(..)
          | socket.Info(..) -> Next(model, [])
        }
      },
    )
  channels
}

fn join_lobby(
  channels: beryl.Sockets,
  socket_id: String,
  join_ref: String,
) -> process.Subject(String) {
  let frames = app_test_helper.connect(channels, socket_id)
  app_test_helper.join_ok(
    channels,
    frames,
    socket_id,
    "room:lobby",
    join_ref,
    "r-1",
  )
  frames
}

pub fn broadcast_reaches_subscribers_across_runtimes_test() -> Nil {
  let scope = "app_bcast_cast"
  let node_a = start_runtime(scope)
  let node_b = start_runtime(scope)

  let observer_b = join_lobby(node_b, "b-observer", "jr-b")
  let sender_a = join_lobby(node_a, "a-sender", "jr-a")
  // Let node_b's join propagate to node_a's pubsub membership.
  process.sleep(50)

  app_test_helper.push(node_a, "a-sender", "room:lobby", "cast", "r-2")

  // The broadcast reaches the local sender and the remote observer.
  app_test_helper.recv(sender_a) |> string.contains("shout") |> should.be_true
  app_test_helper.recv(observer_b) |> string.contains("shout") |> should.be_true
}

pub fn broadcast_from_excludes_sender_across_runtimes_test() -> Nil {
  let scope = "app_bcast_from"
  let node_a = start_runtime(scope)
  let node_b = start_runtime(scope)

  let observer_b = join_lobby(node_b, "b-observer", "jr-b")
  let observer_a = join_lobby(node_a, "a-observer", "jr-a2")
  let sender_a = join_lobby(node_a, "a-sender", "jr-a")
  process.sleep(50)

  app_test_helper.push(node_a, "a-sender", "room:lobby", "cast_others", "r-2")

  // Both observers (local and remote) hear the shout; the sender does not.
  app_test_helper.recv(observer_a) |> string.contains("shout") |> should.be_true
  app_test_helper.recv(observer_b) |> string.contains("shout") |> should.be_true
  app_test_helper.recv_none(sender_a)
}
