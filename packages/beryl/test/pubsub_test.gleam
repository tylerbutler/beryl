import beryl/pubsub
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleeunit/should
import test_helper

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

@external(erlang, "beryl_pubsub_test_ffi", "unavailable")
fn unavailable(operation: fn() -> Nil) -> Bool

@external(erlang, "beryl_pubsub_test_ffi", "kill_registry")
fn kill_registry(scope: atom.Atom) -> Nil

@external(erlang, "beryl_pubsub_test_ffi", "scope_pid")
fn scope_pid(scope: atom.Atom) -> process.Pid

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

pub fn pubsub_scope_recovery_restores_live_memberships_test() -> Nil {
  let scope = atom.create("test_pubsub_scope_recovery")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let started = process.new_subject()
  let starter =
    process.spawn(fn() { process.send(started, pubsub.start(config)) })
  let monitor = process.monitor(starter)
  let assert Ok(instance) = process.receive(started, 5000)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
  let other_handle = pubsub.start(config)
  let first = pubsub.subscriber(instance)
  let second = pubsub.subscriber(other_handle)
  let isolated_scope = atom.create("test_pubsub_scope_recovery_isolated")
  let isolated =
    pubsub.start(pubsub.config_with_scope(atom.to_string(isolated_scope)))
  let isolated_subscriber = pubsub.subscriber(isolated)
  let isolated_pid = scope_pid(isolated_scope)
  let topic = "room:recovery"
  pubsub.join(first, topic)
  pubsub.join(second, topic)
  pubsub.join(first, "room:other")
  pubsub.join(isolated_subscriber, topic)

  list.each(list.repeat(Nil, 2), fn(_) {
    let old_pid = kill_scope(scope)
    test_helper.wait_until(
      fn() { recovered(scope, old_pid, topic, 1) },
      5000,
      10,
    )
    pubsub.subscribers(other_handle, topic) |> should.equal([process.self()])
    pubsub.subscriber_count(instance, "room:other") |> should.equal(1)
    pubsub.join(second, topic)
    pubsub.broadcast(other_handle, topic, "recovered", "payload")
    pubsub.local_broadcast(instance, "room:other", "recovered", "payload")
    pubsub.broadcast(isolated, topic, "isolated", "payload")
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
      let subscriber = pubsub.subscriber(pubsub.start(config))
      pubsub.join(subscriber, topic)
      pubsub.broadcast(instance, topic, "new_owner", "payload")
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
  pubsub.leave(second, topic)
  pubsub.leave(first, topic)
  let old_pid = kill_scope(scope)
  test_helper.wait_until(
    fn() { recovered(scope, old_pid, "room:other", 1) },
    5000,
    10,
  )
  pubsub.subscriber_count(instance, topic) |> should.equal(0)
  pubsub.leave(first, "room:other")
  pubsub.leave(isolated_subscriber, topic)
}

pub fn pubsub_scope_recovery_rejects_unmanaged_scope_test() -> Nil {
  unmanaged_scope_rejected(atom.create("test_pubsub_unmanaged_scope"))
  |> should.be_true
}

pub fn pubsub_scope_recovery_serialises_outage_joins_and_leaves_test() -> Nil {
  let scope = atom.create("test_pubsub_gated_recovery")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let instance = pubsub.start(config)
  let subscriber = pubsub.subscriber(instance)
  let other = pubsub.subscriber(pubsub.start(config))
  pubsub.join(subscriber, "room:leave")
  pubsub.join(subscriber, "room:keep")
  let old_pid =
    during_outage(scope, fn() {
      unavailable(fn() { pubsub.leave(subscriber, "room:leave") })
      |> should.be_true
      unavailable(fn() { pubsub.join(other, "room:new") }) |> should.be_true
      unavailable(fn() { pubsub.join(other, "room:new") }) |> should.be_true
      pubsub.broadcast(instance, "room:keep", "lost", "payload")
      drain_messages(scope, "room:keep", "lost", "payload", pubsub.System)
      |> should.equal(0)
    })
  test_helper.wait_until(
    fn() { recovered(scope, old_pid, "room:keep", 1) },
    5000,
    10,
  )
  pubsub.subscriber_count(instance, "room:leave") |> should.equal(0)
  pubsub.subscriber_count(instance, "room:new") |> should.equal(1)
  pubsub.broadcast(instance, "room:new", "after_outage", "payload")
  drain_messages(scope, "room:new", "after_outage", "payload", pubsub.System)
  |> should.equal(1)
  drain_messages(scope, "room:keep", "lost", "payload", pubsub.System)
  |> should.equal(0)
  pubsub.leave(subscriber, "room:keep")
  pubsub.leave(other, "room:new")
}

pub fn pubsub_scope_recovery_invalidates_handles_after_registry_loss_test() -> Nil {
  let scope = atom.create("test_pubsub_registry_loss")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let instance = pubsub.start(config)
  let subscriber = pubsub.subscriber(instance)
  pubsub.join(subscriber, "room:old")
  let old_pid = scope_pid(scope)
  kill_registry(scope)
  unavailable(fn() {
    pubsub.broadcast(instance, "room:old", "event", "payload")
  })
  |> should.be_true
  test_helper.wait_until(
    fn() { recovered(scope, old_pid, "room:old", 0) },
    5000,
    10,
  )
  let replacement = pubsub.start(config)
  let new_subscriber = pubsub.subscriber(replacement)
  pubsub.join(new_subscriber, "room:new")
  pubsub.broadcast(replacement, "room:new", "fresh_handle", "payload")
  drain_messages(scope, "room:new", "fresh_handle", "payload", pubsub.System)
  |> should.equal(1)
  pubsub.leave(new_subscriber, "room:new")
  unavailable(fn() { pubsub.join(subscriber, "room:new") }) |> should.be_true
  unavailable(fn() { pubsub.leave(subscriber, "room:old") }) |> should.be_true
  unavailable(fn() {
    let _ = pubsub.subscribers(instance, "room:old")
    Nil
  })
  |> should.be_true
}

pub fn pubsub_scope_recovery_concurrent_starts_share_membership_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_concurrent_start")
  let handles = process.new_subject()
  run_concurrently(list.repeat(
    fn() { process.send(handles, pubsub.start(config)) },
    16,
  ))
  let instances =
    list.map(list.repeat(Nil, 16), fn(_) {
      let assert Ok(instance) = process.receive(handles, 5000)
      instance
    })
  let assert [instance, ..] = instances
  list.each(instances, fn(handle) {
    pubsub.join(pubsub.subscriber(handle), "room:shared")
  })
  pubsub.subscribers(instance, "room:shared") |> should.equal([process.self()])
  pubsub.leave(pubsub.subscriber(instance), "room:shared")
}

pub fn pubsub_repeated_joins_are_idempotent_test() -> Nil {
  let scope = atom.create("test_pubsub_repeated_joins")
  let config = pubsub.config_with_scope(atom.to_string(scope))
  let instance = pubsub.start(config)
  let first = pubsub.subscriber(instance)
  let second = pubsub.subscriber(pubsub.start(config))
  let topic = "room:repeated"
  pubsub.join(first, topic)
  pubsub.join(first, topic)
  pubsub.join(second, topic)
  pubsub.join(second, topic)
  let count = pubsub.subscriber_count(instance, topic)
  let members = pubsub.subscribers(instance, topic)

  let sender = process.spawn(fn() { Nil })
  pubsub.broadcast(instance, topic, "broadcast", "payload")
  pubsub.local_broadcast(instance, topic, "local", "payload")
  pubsub.broadcast_from(instance, sender, topic, "from", "payload")
  pubsub.broadcast_from_socket(
    instance,
    sender,
    "socket",
    topic,
    "from_socket",
    "payload",
  )
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

  pubsub.leave(second, topic)
  let after_leave = pubsub.subscriber_count(instance, topic)
  pubsub.broadcast(instance, topic, "after_leave", "payload")
  let after_leave_deliveries =
    drain_messages(scope, topic, "after_leave", "payload", pubsub.System)
  pubsub.leave(first, topic)
  pubsub.leave(second, topic)
  pubsub.leave(first, topic)

  count |> should.equal(1)
  members |> should.equal([process.self()])
  deliveries |> should.equal([1, 1, 1, 1])
  after_leave |> should.equal(0)
  after_leave_deliveries |> should.equal(0)
  pubsub.subscriber_count(instance, topic) |> should.equal(0)
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
  let instance = pubsub.start(config)
  let first = pubsub.subscriber(instance)
  let second = pubsub.subscriber(pubsub.start(config))
  let topic = "room:concurrent"
  let joins =
    [first, second]
    |> list.flat_map(fn(subscriber) {
      list.repeat(fn() { pubsub.join(subscriber, topic) }, 8)
    })

  list.each(list.repeat(Nil, 4), fn(_) {
    run_concurrently(joins)
    let count = pubsub.subscriber_count(instance, topic)
    pubsub.broadcast(instance, topic, "broadcast", "payload")
    let deliveries =
      drain_messages(scope, topic, "broadcast", "payload", pubsub.System)
    pubsub.leave(second, topic)
    let after_leave = pubsub.subscriber_count(instance, topic)
    pubsub.broadcast(instance, topic, "after_leave", "payload")
    let after_leave_deliveries =
      drain_messages(scope, topic, "after_leave", "payload", pubsub.System)
    run_concurrently(list.repeat(fn() { pubsub.leave(first, topic) }, 16))

    count |> should.equal(1)
    deliveries |> should.equal(1)
    after_leave |> should.equal(0)
    after_leave_deliveries |> should.equal(0)
    pubsub.subscriber_count(instance, topic) |> should.equal(0)
  })
}

pub fn pubsub_repeated_leave_preserves_other_memberships_test() -> Nil {
  let scope = atom.create("test_pubsub_leave_isolation")
  let instance = pubsub.start(pubsub.config_with_scope(atom.to_string(scope)))
  let other_scope = atom.create("test_pubsub_leave_other_scope")
  let other_instance =
    pubsub.start(pubsub.config_with_scope(atom.to_string(other_scope)))
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
      pubsub.join(subscriber, topic)
      process.send(ready, finish)
      let assert Ok(Nil) = process.receive(finish, 5000)
      let received =
        drain_messages(scope, topic, "broadcast", "payload", pubsub.System)
      pubsub.leave(subscriber, topic)
      process.send(deliveries, received)
    })
  let assert Ok(finish) = process.receive(ready, 5000)
  pubsub.join(subscriber, topic)
  pubsub.join(subscriber, topic)
  pubsub.join(subscriber, other_topic)
  pubsub.join(other_subscriber, topic)
  pubsub.leave(subscriber, topic)
  let after_leave = pubsub.subscriber_count(instance, topic)
  pubsub.broadcast(instance, topic, "broadcast", "payload")
  let after_leave_deliveries =
    drain_messages(scope, topic, "broadcast", "payload", pubsub.System)
  pubsub.leave(subscriber, topic)
  pubsub.leave(subscriber, topic)
  let after_repeated_leave = pubsub.subscriber_count(instance, topic)
  let other_topic_count = pubsub.subscriber_count(instance, other_topic)
  let other_scope_count = pubsub.subscriber_count(other_instance, topic)
  pubsub.broadcast(instance, other_topic, "broadcast", "payload")
  pubsub.broadcast(other_instance, topic, "broadcast", "payload")
  let other_topic_deliveries =
    drain_messages(scope, other_topic, "broadcast", "payload", pubsub.System)
  let other_scope_deliveries =
    drain_messages(other_scope, topic, "broadcast", "payload", pubsub.System)
  process.send(finish, Nil)
  let assert Ok(owner_deliveries) = process.receive(deliveries, 5000)
  pubsub.leave(subscriber, other_topic)
  pubsub.leave(other_subscriber, topic)

  after_leave |> should.equal(1)
  after_leave_deliveries |> should.equal(0)
  after_repeated_leave |> should.equal(1)
  other_topic_count |> should.equal(1)
  other_scope_count |> should.equal(1)
  other_topic_deliveries |> should.equal(1)
  other_scope_deliveries |> should.equal(1)
  owner_deliveries |> should.equal(1)
  pubsub.subscriber_count(instance, topic) |> should.equal(0)
}

pub fn pubsub_start_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_start")
  let _pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)
  should.be_true(True)
}

pub fn pubsub_start_default_config_test() -> Nil {
  let _pubsub_instance: pubsub.PubSub(String) =
    pubsub.start(pubsub.default_config())
  should.be_true(True)
}

pub fn pubsub_subscribe_and_count_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_sub")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby")
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(1)

  // Cleanup
  pubsub.leave(subscriber, "room:lobby")
}

pub fn pubsub_unsubscribe_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_unsub")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby")
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(1)

  pubsub.leave(subscriber, "room:lobby")
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(0)
}

pub fn pubsub_subscribers_returns_pids_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_pids")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby")
  let subscribers = pubsub.subscribers(pubsub_instance, "room:lobby")
  should.equal(subscribers, [process.self()])

  // Cleanup
  pubsub.leave(subscriber, "room:lobby")
}

pub fn pubsub_broadcast_delivers_message_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_bcast")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby")

  pubsub.broadcast(pubsub_instance, "room:lobby", "new_msg", "hello")

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscriber, fn(message) { message })

  let assert Ok(message) = process.selector_receive(from: selector, within: 100)
  message.topic |> should.equal("room:lobby")
  message.event |> should.equal("new_msg")
  message.payload |> should.equal("hello")
  message.from |> should.equal(pubsub.System)

  // Cleanup
  pubsub.leave(subscriber, "room:lobby")
}

pub fn pubsub_broadcast_uses_scope_tagged_wire_shape_test() -> Nil {
  let scope = "test_pubsub_scoped_wire_shape"
  let config = pubsub.config_with_scope(scope)
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)
  let topic = "wire:raw"
  let event = "shape"
  let payload = "four-fields"

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, topic)
  pubsub.broadcast(pubsub_instance, topic, event, payload)

  is_scoped_wire_message(atom.create(scope), topic, event, payload, 100)
  |> should.be_true

  pubsub.leave(subscriber, topic)
}

pub fn pubsub_selecting_discriminates_scopes_test() -> Nil {
  let text_pubsub: pubsub.PubSub(String) =
    pubsub.start(pubsub.config_with_scope("test_pubsub_scope_text"))
  let number_pubsub: pubsub.PubSub(Int) =
    pubsub.start(pubsub.config_with_scope("test_pubsub_scope_number"))
  let topic = "scope:shared-mailbox"
  let text_subscriber = pubsub.subscriber(text_pubsub)
  let number_subscriber = pubsub.subscriber(number_pubsub)
  pubsub.join(text_subscriber, topic)
  pubsub.join(number_subscriber, topic)

  pubsub.broadcast(number_pubsub, topic, "number", 42)
  pubsub.broadcast(text_pubsub, topic, "text", "correct scope")

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

  pubsub.leave(text_subscriber, topic)
  pubsub.leave(number_subscriber, topic)
}

pub fn pubsub_broadcast_from_excludes_sender_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_bcast_from")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby")

  // Broadcast from self - should NOT receive it
  pubsub.broadcast_from(
    pubsub_instance,
    process.self(),
    "room:lobby",
    "typing",
    "",
  )

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscriber, fn(message) { message })

  // Should time out since we excluded ourselves
  let result = process.selector_receive(from: selector, within: 50)
  should.be_error(result)

  // Cleanup
  pubsub.leave(subscriber, "room:lobby")
}

pub fn pubsub_no_subscribers_is_noop_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_nosubs")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  // Broadcast to topic with no subscribers - should not crash
  pubsub.broadcast(pubsub_instance, "room:empty", "event", "")
  pubsub.subscriber_count(pubsub_instance, "room:empty") |> should.equal(0)
}

pub fn pubsub_multiple_topics_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_multi")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby")
  pubsub.join(subscriber, "room:private")

  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(1)
  pubsub.subscriber_count(pubsub_instance, "room:private") |> should.equal(1)

  // Cleanup
  pubsub.leave(subscriber, "room:lobby")
  pubsub.leave(subscriber, "room:private")
}

pub fn pubsub_one_subscriber_receives_from_multiple_topics_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_multi_recv")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  // A single subscriber joined to two topics receives both topics' messages
  // through its one typed subject — no per-topic subject bookkeeping.
  let subscriber = pubsub.subscriber(pubsub_instance)
  pubsub.join(subscriber, "room:lobby")
  pubsub.join(subscriber, "room:private")

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscriber, fn(message) { message })

  pubsub.broadcast(pubsub_instance, "room:lobby", "a", "one")
  pubsub.broadcast(pubsub_instance, "room:private", "b", "two")

  let assert Ok(first) = process.selector_receive(from: selector, within: 100)
  let assert Ok(second) = process.selector_receive(from: selector, within: 100)

  [first.topic, second.topic]
  |> should.equal(["room:lobby", "room:private"])
  [first.payload, second.payload]
  |> should.equal(["one", "two"])

  // Cleanup
  pubsub.leave(subscriber, "room:lobby")
  pubsub.leave(subscriber, "room:private")
}
