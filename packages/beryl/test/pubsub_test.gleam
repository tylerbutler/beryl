import beryl/error
import beryl/pubsub
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
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

@external(erlang, "beryl_pubsub_test_ffi", "unmanaged_scope_rejected")
fn unmanaged_scope_rejected(scope: atom.Atom) -> Bool

@external(erlang, "beryl_pubsub_test_ffi", "during_outage")
fn during_outage(scope: atom.Atom, operation: fn() -> Nil) -> process.Pid

@external(erlang, "beryl_pubsub_test_ffi", "kill_registry")
fn kill_registry(scope: atom.Atom) -> Nil

@external(erlang, "beryl_pubsub_test_ffi", "scope_pid")
fn scope_pid(scope: atom.Atom) -> process.Pid

@external(erlang, "beryl_pubsub_test_ffi", "healthy_ready_reductions")
fn healthy_ready_reductions(scope: atom.Atom, owner_count: Int) -> Int

@external(erlang, "beryl_pubsub_test_ffi", "timeout_call_cleans_up")
fn timeout_call_cleans_up(scope: atom.Atom) -> Bool

@external(erlang, "beryl_pubsub_test_ffi", "is_scoped_wire_message")
fn is_scoped_wire_message(
  scope: atom.Atom,
  topic: String,
  event: String,
  payload: String,
  timeout: Int,
) -> Bool

@external(erlang, "beryl_pubsub_test_ffi", "drain_messages")
fn drain_messages(
  scope: atom.Atom,
  topic: String,
  event: String,
  payload: String,
  from: pubsub.PubSubFrom,
) -> Int

@external(erlang, "beryl_pubsub_test_ffi", "with_malformed_messages")
fn with_malformed_messages(scope: atom.Atom, receive: fn() -> Nil) -> Bool

@external(erlang, "beryl_pubsub_test_ffi", "nonlocal_leave_preserves_registry")
fn nonlocal_leave_preserves_registry(scope: atom.Atom) -> Bool

@external(erlang, "beryl_pubsub_test_ffi", "call_target")
fn call_target(mode: String) -> process.Subject(process.Subject(Nil))

@external(erlang, "beryl_pubsub_ffi", "membership_actor_call")
fn membership_call(
  subject: process.Subject(process.Subject(Nil)),
  timeout: Int,
  request: fn(process.Subject(Nil)) -> process.Subject(Nil),
) -> Result(Nil, error.CallError)

@external(erlang, "beryl_pubsub_test_ffi", "operation_failure")
fn operation_failure(shape: String) -> error.OperationFailure

@external(erlang, "beryl_pubsub_test_ffi", "with_unmanaged_scope")
fn with_unmanaged_scope(scope: atom.Atom, action: fn() -> Nil) -> Nil

@external(erlang, "beryl_pubsub_test_ffi", "with_suspended_registry")
fn with_suspended_registry(
  scope: atom.Atom,
  action: fn(process.Pid) -> Nil,
) -> Nil

@external(erlang, "beryl_pubsub_test_ffi", "with_unreconciled_scope")
fn with_unreconciled_scope(scope: atom.Atom, action: fn() -> Nil) -> Nil

pub fn queries_and_broadcasts_do_not_call_suspended_registry_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = atom.create("test_pubsub_nonblocking_queries")
  let instance =
    pubsub.start(pubsub.config_with_scope(atom.to_string(scope)))
    |> should.be_ok
  let subscriber = pubsub.subscriber(instance)
  let topic = "room:nonblocking"
  pubsub.join(subscriber, topic) |> should.be_ok
  with_suspended_registry(scope, fn(_) {
    pubsub.subscribers(instance, topic)
    |> should.equal(Ok([process.self()]))
    pubsub.subscriber_count(instance, topic) |> should.equal(Ok(1))
    pubsub.broadcast(instance, topic, "global", "payload") |> should.be_ok
    pubsub.local_broadcast(instance, topic, "local", "payload") |> should.be_ok
    drain_messages(scope, topic, "global", "payload", pubsub.System)
    |> should.equal(1)
    drain_messages(scope, topic, "local", "payload", pubsub.System)
    |> should.equal(1)
  })
  pubsub.leave(subscriber, topic) |> should.be_ok
}

pub fn queries_reject_unreconciled_replacement_pg_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = atom.create("test_pubsub_generation_queries")
  let instance =
    pubsub.start(pubsub.config_with_scope(atom.to_string(scope)))
    |> should.be_ok
  let subscriber = pubsub.subscriber(instance)
  let topic = "room:unreconciled"
  pubsub.join(subscriber, topic) |> should.be_ok
  with_unreconciled_scope(scope, fn() {
    pubsub.subscribers(instance, topic)
    |> should.equal(Error(pubsub.ScopeRecovering))
    pubsub.subscriber_count(instance, topic)
    |> should.equal(Error(pubsub.ScopeRecovering))
    pubsub.broadcast(instance, topic, "global", "lost")
    |> should.equal(Error(pubsub.ScopeRecovering))
    pubsub.local_broadcast(instance, topic, "local", "lost")
    |> should.equal(Error(pubsub.ScopeRecovering))
    pubsub.broadcast_from(instance, process.self(), topic, "from", "lost")
    |> should.equal(Error(pubsub.ScopeRecovering))
    pubsub.local_broadcast_from(instance, process.self(), topic, "from", "lost")
    |> should.equal(Error(pubsub.ScopeRecovering))
    pubsub.broadcast_from_socket(
      instance,
      process.self(),
      "socket",
      topic,
      "socket",
      "lost",
    )
    |> should.equal(Error(pubsub.ScopeRecovering))
  })
  test_helper.wait_until(
    fn() { pubsub.subscribers(instance, topic) == Ok([process.self()]) },
    5000,
    10,
  )
  pubsub.broadcast(instance, topic, "replayed", "payload") |> should.be_ok
  drain_messages(scope, topic, "replayed", "payload", pubsub.System)
  |> should.equal(1)
  pubsub.leave(subscriber, topic) |> should.be_ok
}

pub fn startup_conflict_returns_original_failure_test() -> Nil {
  let scope = "test_pubsub_typed_startup_conflict"
  with_unmanaged_scope(atom.create(scope), fn() {
    let assert Error(pubsub.StartupFailed(reason)) =
      pubsub.start(pubsub.config_with_scope(scope))
    error.describe_operation_failure(reason)
    |> string.contains("already_started")
    |> should.be_true
  })
  let _: pubsub.PubSub(String) =
    pubsub.start(pubsub.config_with_scope(scope)) |> should.be_ok
  Nil
}

pub fn native_operation_failure_diagnostics_are_bounded_test() -> Nil {
  let failure = operation_failure("large")
  { string.length(error.describe_operation_failure(failure)) <= 512 }
  |> should.be_true
  error.describe_operation_failure(operation_failure("unicode"))
  |> string.contains("café")
  |> should.be_true
  pubsub.describe_error(pubsub.PgUnavailable(failure))
  |> string.contains("native_failure")
  |> should.be_true
}

pub fn membership_call_preserves_down_reason_and_cleans_up_test() -> Nil {
  let monitors = test_helper.monitor_count(process.self())
  let messages = test_helper.mailbox_length(process.self())
  let assert Error(error.CallDown(reason)) =
    membership_call(call_target("down"), 1000, fn(reply) { reply })
  pubsub.describe_error(pubsub.MembershipCallFailed(error.CallDown(reason)))
  |> should.equal(
    "PubSub membership call failed: actor exited: abnormal: {test_call_failure,42,<<\"original\">>}",
  )
  test_helper.monitor_count(process.self()) |> should.equal(monitors)
  test_helper.mailbox_length(process.self()) |> should.equal(messages)
  membership_call(call_target("success"), 1000, fn(reply) { reply })
  |> should.equal(Ok(Nil))
  test_helper.monitor_count(process.self()) |> should.equal(monitors)
  test_helper.mailbox_length(process.self()) |> should.equal(messages)
}

pub fn nonlocal_leave_does_not_restart_registry_test() -> Nil {
  use <- unitest.tag("serial")
  nonlocal_leave_preserves_registry(atom.create("test_pubsub_nonlocal_leave"))
  |> should.be_true
}

pub fn pubsub_membership_ready_cost_is_bounded_test() -> Nil {
  let reductions =
    healthy_ready_reductions(
      atom.create("test_pubsub_membership_ready_cost"),
      4096,
    )
  { reductions < 2000 } |> should.be_true
}

pub fn pubsub_membership_timeout_cleans_up_call_state_test() -> Nil {
  timeout_call_cleans_up(atom.create("test_pubsub_membership_timeout"))
  |> should.be_true
}

pub fn pubsub_scope_recovery_restores_live_memberships_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = atom.create("test_pubsub_scope_recovery")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let started = process.new_subject()
  let starter =
    process.spawn(fn() {
      process.send(started, pubsub.start(config) |> should.be_ok)
    })
  let monitor = process.monitor(starter)
  let assert Ok(instance) = process.receive(started, 5000)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
  let other_handle = pubsub.start(config) |> should.be_ok
  let first = pubsub.subscriber(instance)
  let second = pubsub.subscriber(other_handle)
  let isolated_scope = atom.create("test_pubsub_scope_recovery_isolated")
  let isolated =
    pubsub.start(pubsub.config_with_scope(atom.to_string(isolated_scope)))
    |> should.be_ok
  let isolated_subscriber = pubsub.subscriber(isolated)
  let isolated_pid = scope_pid(isolated_scope)
  let topic = "room:recovery"
  pubsub.join(first, topic) |> should.be_ok
  pubsub.join(second, topic) |> should.be_ok
  pubsub.join(first, "room:other") |> should.be_ok
  pubsub.join(isolated_subscriber, topic) |> should.be_ok

  list.each(list.repeat(Nil, 2), fn(_) {
    let old_pid = kill_scope(scope)
    test_helper.wait_until(
      fn() { recovered(scope, old_pid, topic, 1) },
      5000,
      10,
    )
    pubsub.subscribers(other_handle, topic)
    |> should.equal(Ok([process.self()]))
    pubsub.subscriber_count(instance, "room:other") |> should.equal(Ok(1))
    pubsub.join(second, topic) |> should.be_ok
    pubsub.broadcast(other_handle, topic, "recovered", "payload")
    |> should.be_ok
    pubsub.local_broadcast(instance, "room:other", "recovered", "payload")
    |> should.be_ok
    pubsub.broadcast(isolated, topic, "isolated", "payload") |> should.be_ok
    drain_messages(scope, topic, "recovered", "payload", pubsub.System)
    |> should.equal(1)
    drain_messages(scope, "room:other", "recovered", "payload", pubsub.System)
    |> should.equal(1)
    drain_messages(isolated_scope, topic, "isolated", "payload", pubsub.System)
    |> should.equal(1)
    scope_pid(isolated_scope) |> should.equal(isolated_pid)
  })

  let delivered = process.new_subject()
  let new_owner =
    process.spawn(fn() {
      let subscriber = pubsub.subscriber(pubsub.start(config) |> should.be_ok)
      pubsub.join(subscriber, topic) |> should.be_ok
      pubsub.broadcast(instance, topic, "new_owner", "payload") |> should.be_ok
      let received =
        drain_messages(scope, topic, "new_owner", "payload", pubsub.System)
      process.send(delivered, received)
    })
  let monitor = process.monitor(new_owner)
  process.receive(delivered, 5000) |> should.equal(Ok(1))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
  drain_messages(scope, topic, "new_owner", "payload", pubsub.System)
  |> should.equal(1)
  let old_pid = kill_scope(scope)
  test_helper.wait_until(fn() { recovered(scope, old_pid, topic, 1) }, 5000, 10)
  pubsub.leave(second, topic) |> should.be_ok
  pubsub.leave(first, topic) |> should.be_ok
  let old_pid = kill_scope(scope)
  test_helper.wait_until(
    fn() { recovered(scope, old_pid, "room:other", 1) },
    5000,
    10,
  )
  pubsub.subscriber_count(instance, topic) |> should.equal(Ok(0))
  pubsub.leave(first, "room:other") |> should.be_ok
  pubsub.leave(isolated_subscriber, topic) |> should.be_ok
}

pub fn pubsub_scope_recovery_rejects_unmanaged_scope_test() -> Nil {
  unmanaged_scope_rejected(atom.create("test_pubsub_unmanaged_scope"))
  |> should.be_true
}

pub fn pubsub_scope_recovery_serialises_outage_joins_and_leaves_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = atom.create("test_pubsub_gated_recovery")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let instance = pubsub.start(config) |> should.be_ok
  let subscriber = pubsub.subscriber(instance)
  let other = pubsub.subscriber(pubsub.start(config) |> should.be_ok)
  pubsub.join(subscriber, "room:leave") |> should.be_ok
  pubsub.join(subscriber, "room:keep") |> should.be_ok
  let old_pid =
    during_outage(scope, fn() {
      pubsub.leave(subscriber, "room:leave")
      |> should.equal(Error(pubsub.ScopeRecovering))
      pubsub.join(other, "room:new")
      |> should.equal(Error(pubsub.ScopeRecovering))
      pubsub.join(other, "room:new")
      |> should.equal(Error(pubsub.ScopeRecovering))
      pubsub.broadcast(instance, "room:keep", "lost", "payload")
      |> should.equal(Error(pubsub.ScopeRecovering))
      pubsub.subscribers(instance, "room:keep")
      |> should.equal(Error(pubsub.ScopeRecovering))
      drain_messages(scope, "room:keep", "lost", "payload", pubsub.System)
      |> should.equal(0)
    })
  test_helper.wait_until(
    fn() { recovered(scope, old_pid, "room:new", 1) },
    5000,
    10,
  )
  pubsub.subscriber_count(instance, "room:keep") |> should.equal(Ok(1))
  pubsub.subscriber_count(instance, "room:leave") |> should.equal(Ok(0))
  pubsub.broadcast(instance, "room:new", "after_outage", "payload")
  |> should.be_ok
  drain_messages(scope, "room:new", "after_outage", "payload", pubsub.System)
  |> should.equal(1)
  drain_messages(scope, "room:keep", "lost", "payload", pubsub.System)
  |> should.equal(0)
  pubsub.leave(subscriber, "room:keep") |> should.be_ok
  pubsub.leave(other, "room:new") |> should.be_ok
}

pub fn pubsub_scope_recovery_invalidates_handles_after_registry_loss_test() -> Nil {
  use <- unitest.tag("serial")
  let scope = atom.create("test_pubsub_registry_loss")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let instance = pubsub.start(config) |> should.be_ok
  let subscriber = pubsub.subscriber(instance)
  pubsub.join(subscriber, "room:old") |> should.be_ok
  let old_pid = scope_pid(scope)
  kill_registry(scope)
  let unavailable = pubsub.MembershipCallFailed(error.CallUnavailable)
  pubsub.broadcast(instance, "room:old", "event", "payload")
  |> should.equal(Error(unavailable))
  test_helper.wait_until(
    fn() { recovered(scope, old_pid, "room:old", 0) },
    5000,
    10,
  )
  let replacement = pubsub.start(config) |> should.be_ok
  let new_subscriber = pubsub.subscriber(replacement)
  pubsub.join(new_subscriber, "room:new") |> should.be_ok
  pubsub.broadcast(replacement, "room:new", "fresh_handle", "payload")
  |> should.be_ok
  drain_messages(scope, "room:new", "fresh_handle", "payload", pubsub.System)
  |> should.equal(1)
  pubsub.leave(new_subscriber, "room:new") |> should.be_ok
  pubsub.join(subscriber, "room:new") |> should.equal(Error(unavailable))
  pubsub.leave(subscriber, "room:old") |> should.equal(Error(unavailable))
  pubsub.subscribers(instance, "room:old") |> should.equal(Error(unavailable))
  pubsub.subscriber_count(instance, "room:old")
  |> should.equal(Error(unavailable))
  pubsub.local_broadcast(instance, "room:old", "event", "payload")
  |> should.equal(Error(unavailable))
}

pub fn pubsub_scope_recovery_concurrent_starts_share_membership_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_concurrent_start")
  let handles = process.new_subject()
  run_concurrently(list.repeat(
    fn() { process.send(handles, pubsub.start(config) |> should.be_ok) },
    16,
  ))
  let instances =
    list.map(list.repeat(Nil, 16), fn(_) {
      let assert Ok(instance) = process.receive(handles, 5000)
      instance
    })
  let assert [instance, ..] = instances
  list.each(instances, fn(handle) {
    pubsub.join(pubsub.subscriber(handle), "room:shared") |> should.be_ok
  })
  pubsub.subscribers(instance, "room:shared")
  |> should.equal(Ok([process.self()]))
  pubsub.leave(pubsub.subscriber(instance), "room:shared") |> should.be_ok
}

pub fn pubsub_repeated_joins_are_idempotent_test() -> Nil {
  let scope = atom.create("test_pubsub_repeated_joins")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let instance = pubsub.start(config) |> should.be_ok
  let first = pubsub.subscriber(instance)
  let second = pubsub.subscriber(pubsub.start(config) |> should.be_ok)
  let topic = "room:repeated"
  pubsub.join(first, topic) |> should.be_ok
  pubsub.join(first, topic) |> should.be_ok
  pubsub.join(second, topic) |> should.be_ok
  pubsub.join(second, topic) |> should.be_ok
  let count = pubsub.subscriber_count(instance, topic) |> should.be_ok
  let members = pubsub.subscribers(instance, topic) |> should.be_ok

  let sender = process.spawn(fn() { Nil })
  pubsub.broadcast(instance, topic, "broadcast", "payload") |> should.be_ok
  pubsub.local_broadcast(instance, topic, "local", "payload") |> should.be_ok
  pubsub.broadcast_from(instance, sender, topic, "from", "payload")
  |> should.be_ok
  pubsub.broadcast_from_socket(
    instance,
    sender,
    "socket",
    topic,
    "from_socket",
    "payload",
  )
  |> should.be_ok
  let deliveries = [
    drain_messages(scope, topic, "broadcast", "payload", pubsub.System),
    drain_messages(scope, topic, "local", "payload", pubsub.System),
    drain_messages(scope, topic, "from", "payload", pubsub.FromPid(sender)),
    drain_messages(
      scope,
      topic,
      "from_socket",
      "payload",
      pubsub.FromSocket(sender, "socket"),
    ),
  ]

  pubsub.leave(second, topic) |> should.be_ok
  let after_leave = pubsub.subscriber_count(instance, topic) |> should.be_ok
  pubsub.broadcast(instance, topic, "after_leave", "payload") |> should.be_ok
  let after_leave_deliveries =
    drain_messages(scope, topic, "after_leave", "payload", pubsub.System)
  pubsub.leave(first, topic) |> should.be_ok
  pubsub.leave(second, topic) |> should.be_ok
  pubsub.leave(first, topic) |> should.be_ok

  count |> should.equal(1)
  members |> should.equal([process.self()])
  deliveries |> should.equal([1, 1, 1, 1])
  after_leave |> should.equal(0)
  after_leave_deliveries |> should.equal(0)
  pubsub.subscriber_count(instance, topic) |> should.equal(Ok(0))
}

fn run_concurrently(operations: List(fn() -> Nil)) -> Nil {
  let ready = process.new_subject()
  let done = process.new_subject()
  list.each(operations, fn(operation) {
    let _worker =
      process.spawn(fn() {
        let start = process.new_subject()
        process.send(ready, start)
        let assert Ok(Nil) = process.receive(start, 5000)
        operation()
        process.send(done, Nil)
      })
  })
  let starts =
    list.map(operations, fn(_) {
      let assert Ok(start) = process.receive(ready, 5000)
      start
    })
  list.each(starts, process.send(_, Nil))
  list.each(operations, fn(_) {
    let assert Ok(Nil) = process.receive(done, 5000)
    Nil
  })
}

pub fn pubsub_concurrent_joins_are_idempotent_test() -> Nil {
  let scope = atom.create("test_pubsub_concurrent_joins")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let instance = pubsub.start(config) |> should.be_ok
  let first = pubsub.subscriber(instance)
  let second = pubsub.subscriber(pubsub.start(config) |> should.be_ok)
  let topic = "room:concurrent"
  let joins =
    [first, second]
    |> list.flat_map(fn(subscriber) {
      list.repeat(fn() { pubsub.join(subscriber, topic) |> should.be_ok }, 8)
    })

  list.each(list.repeat(Nil, 4), fn(_) {
    run_concurrently(joins)
    let count = pubsub.subscriber_count(instance, topic) |> should.be_ok
    pubsub.broadcast(instance, topic, "broadcast", "payload") |> should.be_ok
    let deliveries =
      drain_messages(scope, topic, "broadcast", "payload", pubsub.System)
    pubsub.leave(second, topic) |> should.be_ok
    let after_leave = pubsub.subscriber_count(instance, topic) |> should.be_ok
    pubsub.broadcast(instance, topic, "after_leave", "payload") |> should.be_ok
    let after_leave_deliveries =
      drain_messages(scope, topic, "after_leave", "payload", pubsub.System)
    run_concurrently(list.repeat(
      fn() { pubsub.leave(first, topic) |> should.be_ok },
      16,
    ))

    count |> should.equal(1)
    deliveries |> should.equal(1)
    after_leave |> should.equal(0)
    after_leave_deliveries |> should.equal(0)
    pubsub.subscriber_count(instance, topic) |> should.equal(Ok(0))
  })
}

pub fn pubsub_repeated_leave_preserves_other_memberships_test() -> Nil {
  let scope = atom.create("test_pubsub_leave_isolation")
  let instance =
    pubsub.start(pubsub.config_with_scope(atom.to_string(scope)))
    |> should.be_ok
  let other_scope = atom.create("test_pubsub_leave_other_scope")
  let other_instance =
    pubsub.start(pubsub.config_with_scope(atom.to_string(other_scope)))
    |> should.be_ok
  let subscriber = pubsub.subscriber(instance)
  let other_subscriber = pubsub.subscriber(other_instance)
  let topic = "room:shared"
  let other_topic = "room:other"
  let ready = process.new_subject()
  let deliveries = process.new_subject()
  let _owner =
    process.spawn(fn() {
      let finish = process.new_subject()
      let subscriber = pubsub.subscriber(instance)
      pubsub.join(subscriber, topic) |> should.be_ok
      process.send(ready, finish)
      let assert Ok(Nil) = process.receive(finish, 5000)
      let received =
        drain_messages(scope, topic, "broadcast", "payload", pubsub.System)
      pubsub.leave(subscriber, topic) |> should.be_ok
      process.send(deliveries, received)
    })
  let assert Ok(finish) = process.receive(ready, 5000)
  pubsub.join(subscriber, topic) |> should.be_ok
  pubsub.join(subscriber, topic) |> should.be_ok
  pubsub.join(subscriber, other_topic) |> should.be_ok
  pubsub.join(other_subscriber, topic) |> should.be_ok
  pubsub.leave(subscriber, topic) |> should.be_ok
  let after_leave = pubsub.subscriber_count(instance, topic) |> should.be_ok
  pubsub.broadcast(instance, topic, "broadcast", "payload") |> should.be_ok
  let after_leave_deliveries =
    drain_messages(scope, topic, "broadcast", "payload", pubsub.System)
  pubsub.leave(subscriber, topic) |> should.be_ok
  pubsub.leave(subscriber, topic) |> should.be_ok
  let after_repeated_leave =
    pubsub.subscriber_count(instance, topic) |> should.be_ok
  let other_topic_count =
    pubsub.subscriber_count(instance, other_topic) |> should.be_ok
  let other_scope_count =
    pubsub.subscriber_count(other_instance, topic) |> should.be_ok
  pubsub.broadcast(instance, other_topic, "broadcast", "payload")
  |> should.be_ok
  pubsub.broadcast(other_instance, topic, "broadcast", "payload")
  |> should.be_ok
  let other_topic_deliveries =
    drain_messages(scope, other_topic, "broadcast", "payload", pubsub.System)
  let other_scope_deliveries =
    drain_messages(other_scope, topic, "broadcast", "payload", pubsub.System)
  process.send(finish, Nil)
  let assert Ok(owner_deliveries) = process.receive(deliveries, 5000)
  pubsub.leave(subscriber, other_topic) |> should.be_ok
  pubsub.leave(other_subscriber, topic) |> should.be_ok

  after_leave |> should.equal(1)
  after_leave_deliveries |> should.equal(0)
  after_repeated_leave |> should.equal(1)
  other_topic_count |> should.equal(1)
  other_scope_count |> should.equal(1)
  other_topic_deliveries |> should.equal(1)
  other_scope_deliveries |> should.equal(1)
  owner_deliveries |> should.equal(1)
  pubsub.subscriber_count(instance, topic) |> should.equal(Ok(0))
}

pub fn pubsub_start_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_start")
  let _pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok
  should.be_true(True)
}

pub fn pubsub_start_default_config_test() -> Nil {
  let _pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(pubsub.default_config()) |> should.be_ok
  should.be_true(True)
}

pub fn pubsub_subscribe_and_count_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_sub")
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby") |> should.be_ok
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(Ok(1))

  // Cleanup
  pubsub.leave(subscriber, "room:lobby") |> should.be_ok
}

pub fn pubsub_unsubscribe_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_unsub")
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby") |> should.be_ok
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(Ok(1))

  pubsub.leave(subscriber, "room:lobby") |> should.be_ok
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(Ok(0))
}

pub fn pubsub_subscribers_returns_pids_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_pids")
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby") |> should.be_ok
  let subscribers =
    pubsub.subscribers(pubsub_instance, "room:lobby") |> should.be_ok
  should.equal(subscribers, [process.self()])

  // Cleanup
  pubsub.leave(subscriber, "room:lobby") |> should.be_ok
}

pub fn pubsub_broadcast_delivers_message_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_bcast")
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby") |> should.be_ok

  pubsub.broadcast(pubsub_instance, "room:lobby", "new_msg", "hello")
  |> should.be_ok

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscriber, fn(message) { message })

  let assert Ok(message) = process.selector_receive(from: selector, within: 100)
  let pubsub.Message(topic, event, payload, from) = message
  topic |> should.equal("room:lobby")
  event |> should.equal("new_msg")
  payload |> should.equal("hello")
  from |> should.equal(pubsub.System)

  // Cleanup
  pubsub.leave(subscriber, "room:lobby") |> should.be_ok
}

pub fn pubsub_broadcast_uses_scope_tagged_wire_shape_test() -> Nil {
  let scope = "test_pubsub_scoped_wire_shape"
  let config = pubsub.config_with_scope(scope)
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok
  let topic = "wire:raw"
  let event = "shape"
  let payload = "four-fields"

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, topic) |> should.be_ok
  pubsub.broadcast(pubsub_instance, topic, event, payload) |> should.be_ok

  is_scoped_wire_message(atom.create(scope), topic, event, payload, 100)
  |> should.be_true

  pubsub.leave(subscriber, topic) |> should.be_ok
}

pub fn pubsub_same_scope_handles_share_typed_delivery_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_same_scope_contract")
  let first: pubsub.PubSub(String) = pubsub.start(config) |> should.be_ok
  let second: pubsub.PubSub(String) = pubsub.start(config) |> should.be_ok
  let first_subscriber = pubsub.subscriber(first)
  let second_subscriber = pubsub.subscriber(second)
  let topic = "scope:shared-handles"
  pubsub.join(first_subscriber, topic) |> should.be_ok
  pubsub.join(second_subscriber, topic) |> should.be_ok

  let first_selector =
    process.new_selector()
    |> pubsub.selecting(first_subscriber, fn(message) { message })
  let second_selector =
    process.new_selector()
    |> pubsub.selecting(second_subscriber, fn(message) { message })

  pubsub.broadcast(first, topic, "first", "from first") |> should.be_ok
  process.selector_receive(second_selector, 100)
  |> should.equal(
    Ok(pubsub.Message(topic, "first", "from first", pubsub.System)),
  )
  pubsub.broadcast(second, topic, "second", "from second") |> should.be_ok
  process.selector_receive(first_selector, 100)
  |> should.equal(
    Ok(pubsub.Message(topic, "second", "from second", pubsub.System)),
  )
  process.selector_receive(first_selector, 0) |> should.equal(Error(Nil))
  pubsub.leave(second_subscriber, topic) |> should.be_ok
  pubsub.subscriber_count(first, topic) |> should.equal(Ok(0))
}

pub fn pubsub_selecting_ignores_malformed_outer_tuples_test() -> Nil {
  let scope = atom.create("test_pubsub_malformed_outer_tuples")
  let instance: pubsub.PubSub(String) =
    pubsub.start(pubsub.config_with_scope(atom.to_string(scope)))
    |> should.be_ok
  let subscriber = pubsub.subscriber(instance)
  let topic = "scope:malformed"
  pubsub.join(subscriber, topic) |> should.be_ok
  let selector =
    process.new_selector()
    |> pubsub.selecting(subscriber, fn(message) { message })

  with_malformed_messages(scope, fn() {
    pubsub.broadcast(instance, topic, "valid", "still delivered")
    |> should.be_ok
    process.selector_receive(selector, 100)
    |> should.equal(
      Ok(pubsub.Message(topic, "valid", "still delivered", pubsub.System)),
    )
    process.selector_receive(selector, 0) |> should.equal(Error(Nil))
  })
  |> should.be_true
  pubsub.leave(subscriber, topic) |> should.be_ok
}

pub fn pubsub_selecting_discriminates_scopes_test() -> Nil {
  let text_pubsub: pubsub.PubSub(String) =
    pubsub.start(pubsub.config_with_scope("test_pubsub_scope_text"))
    |> should.be_ok
  let number_pubsub: pubsub.PubSub(Int) =
    pubsub.start(pubsub.config_with_scope("test_pubsub_scope_number"))
    |> should.be_ok
  let topic = "scope:shared-mailbox"
  let text_subscriber = pubsub.subscriber(text_pubsub)
  let number_subscriber = pubsub.subscriber(number_pubsub)
  pubsub.join(text_subscriber, topic) |> should.be_ok
  pubsub.join(number_subscriber, topic) |> should.be_ok

  pubsub.broadcast(number_pubsub, topic, "number", 42) |> should.be_ok
  pubsub.broadcast(text_pubsub, topic, "text", "correct scope") |> should.be_ok

  let text_selector =
    process.new_selector()
    |> pubsub.selecting(text_subscriber, fn(message) { message.payload })
  let assert Ok(text) =
    process.selector_receive(from: text_selector, within: 100)
  text |> should.equal("correct scope")

  let number_selector =
    process.new_selector()
    |> pubsub.selecting(number_subscriber, fn(message) { message.payload })
  let assert Ok(number) =
    process.selector_receive(from: number_selector, within: 100)
  number |> should.equal(42)

  pubsub.leave(text_subscriber, topic) |> should.be_ok
  pubsub.leave(number_subscriber, topic) |> should.be_ok
}

pub fn pubsub_broadcast_from_excludes_sender_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_bcast_from")
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby") |> should.be_ok

  // Broadcast from self - should NOT receive it
  pubsub.broadcast_from(
    pubsub_instance,
    process.self(),
    "room:lobby",
    "typing",
    "",
  )
  |> should.be_ok

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscriber, fn(message) { message })

  // Should time out since we excluded ourselves
  let result = process.selector_receive(from: selector, within: 50)
  should.be_error(result)

  // Cleanup
  pubsub.leave(subscriber, "room:lobby") |> should.be_ok
}

pub fn pubsub_no_subscribers_is_noop_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_nosubs")
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok

  // Broadcast to topic with no subscribers - should not crash
  pubsub.broadcast(pubsub_instance, "room:empty", "event", "") |> should.be_ok
  pubsub.subscriber_count(pubsub_instance, "room:empty") |> should.equal(Ok(0))
}

pub fn pubsub_multiple_topics_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_multi")
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby") |> should.be_ok
  pubsub.join(subscriber, "room:private") |> should.be_ok

  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(Ok(1))
  pubsub.subscriber_count(pubsub_instance, "room:private")
  |> should.equal(Ok(1))

  // Cleanup
  pubsub.leave(subscriber, "room:lobby") |> should.be_ok
  pubsub.leave(subscriber, "room:private") |> should.be_ok
}

pub fn pubsub_one_subscriber_receives_from_multiple_topics_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_multi_recv")
  let pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(config) |> should.be_ok

  // A single subscriber joined to two topics receives both topics' messages
  // through its one typed subject — no per-topic subject bookkeeping.
  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby") |> should.be_ok
  pubsub.join(subscriber, "room:private") |> should.be_ok

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscriber, fn(message) { message })

  pubsub.broadcast(pubsub_instance, "room:lobby", "a", "one") |> should.be_ok
  pubsub.broadcast(pubsub_instance, "room:private", "b", "two") |> should.be_ok

  let assert Ok(first) = process.selector_receive(from: selector, within: 100)
  let assert Ok(second) = process.selector_receive(from: selector, within: 100)

  [first.topic, second.topic]
  |> should.equal(["room:lobby", "room:private"])
  [first.payload, second.payload]
  |> should.equal(["one", "two"])

  // Cleanup
  pubsub.leave(subscriber, "room:lobby") |> should.be_ok
  pubsub.leave(subscriber, "room:private") |> should.be_ok
}
