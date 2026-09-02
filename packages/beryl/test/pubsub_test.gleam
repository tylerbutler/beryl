import beryl/pubsub
import gleam/erlang/atom
import gleam/erlang/process
import gleeunit/should

@external(erlang, "beryl_pubsub_test_ffi", "is_scoped_wire_message")
fn is_scoped_wire_message(
  scope: atom.Atom,
  topic: String,
  event: String,
  payload: String,
  timeout: Int,
) -> Bool

pub fn pubsub_start_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_start")
  let _ps: pubsub.PubSub(String) = pubsub.start(config)
  should.be_true(True)
}

pub fn pubsub_start_default_config_test() -> Nil {
  let _ps: pubsub.PubSub(String) = pubsub.start(pubsub.default_config())
  should.be_true(True)
}

pub fn pubsub_subscribe_and_count_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_sub")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(pubsub_instance)
  pubsub.join(sub, "room:lobby")
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(1)

  // Cleanup
  pubsub.leave(sub, "room:lobby")
}

pub fn pubsub_unsubscribe_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_unsub")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(pubsub_instance)
  pubsub.join(sub, "room:lobby")
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(1)

  pubsub.leave(sub, "room:lobby")
  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(0)
}

pub fn pubsub_subscribers_returns_pids_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_pids")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(pubsub_instance)
  pubsub.join(sub, "room:lobby")
  let subs = pubsub.subscribers(pubsub_instance, "room:lobby")
  should.equal(subs, [process.self()])

  // Cleanup
  pubsub.leave(sub, "room:lobby")
}

pub fn pubsub_broadcast_delivers_message_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_bcast")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(pubsub_instance)
  pubsub.join(sub, "room:lobby")

  pubsub.broadcast(pubsub_instance, "room:lobby", "new_msg", "hello")

  let selector =
    process.new_selector()
    |> pubsub.selecting(sub, fn(message) { message })

  let assert Ok(message) = process.selector_receive(from: selector, within: 100)
  message.topic |> should.equal("room:lobby")
  message.event |> should.equal("new_msg")
  message.payload |> should.equal("hello")
  message.from |> should.equal(pubsub.System)

  // Cleanup
  pubsub.leave(sub, "room:lobby")
}

pub fn pubsub_broadcast_uses_scope_tagged_wire_shape_test() -> Nil {
  let scope = "test_pubsub_scoped_wire_shape"
  let config = pubsub.config_with_scope(scope)
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)
  let topic = "wire:raw"
  let event = "shape"
  let payload = "four-fields"

  let sub = pubsub.subscriber(pubsub_instance)
  pubsub.join(sub, topic)
  pubsub.broadcast(pubsub_instance, topic, event, payload)

  is_scoped_wire_message(atom.create(scope), topic, event, payload, 100)
  |> should.be_true

  pubsub.leave(sub, topic)
}

pub fn pubsub_selecting_discriminates_scopes_test() -> Nil {
  let text_ps: pubsub.PubSub(String) =
    pubsub.start(pubsub.config_with_scope("test_pubsub_scope_text"))
  let number_ps: pubsub.PubSub(Int) =
    pubsub.start(pubsub.config_with_scope("test_pubsub_scope_number"))
  let topic = "scope:shared-mailbox"
  let text_sub = pubsub.subscriber(text_ps)
  let number_sub = pubsub.subscriber(number_ps)
  pubsub.join(text_sub, topic)
  pubsub.join(number_sub, topic)

  pubsub.broadcast(number_ps, topic, "number", 42)
  pubsub.broadcast(text_ps, topic, "text", "correct scope")

  let text_selector =
    process.new_selector()
    |> pubsub.selecting(text_sub, fn(message) { message.payload })
  let assert Ok(text) =
    process.selector_receive(from: text_selector, within: 100)
  text |> should.equal("correct scope")

  let number_selector =
    process.new_selector()
    |> pubsub.selecting(number_sub, fn(message) { message.payload })
  let assert Ok(number) =
    process.selector_receive(from: number_selector, within: 100)
  number |> should.equal(42)

  pubsub.leave(text_sub, topic)
  pubsub.leave(number_sub, topic)
}

pub fn pubsub_broadcast_from_excludes_sender_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_bcast_from")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(pubsub_instance)
  pubsub.join(sub, "room:lobby")

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
    |> pubsub.selecting(sub, fn(message) { message })

  // Should time out since we excluded ourselves
  let result = process.selector_receive(from: selector, within: 50)
  should.be_error(result)

  // Cleanup
  pubsub.leave(sub, "room:lobby")
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

  let sub = pubsub.subscriber(pubsub_instance)
  pubsub.join(sub, "room:lobby")
  pubsub.join(sub, "room:private")

  pubsub.subscriber_count(pubsub_instance, "room:lobby") |> should.equal(1)
  pubsub.subscriber_count(pubsub_instance, "room:private") |> should.equal(1)

  // Cleanup
  pubsub.leave(sub, "room:lobby")
  pubsub.leave(sub, "room:private")
}

pub fn pubsub_one_subscriber_receives_from_multiple_topics_test() -> Nil {
  let config = pubsub.config_with_scope("test_pubsub_multi_recv")
  let pubsub_instance: pubsub.PubSub(String) = pubsub.start(config)

  // A single subscriber joined to two topics receives both topics' messages
  // through its one typed subject — no per-topic subject bookkeeping.
  let sub = pubsub.subscriber(pubsub_instance)
  pubsub.join(sub, "room:lobby")
  pubsub.join(sub, "room:private")

  let selector =
    process.new_selector()
    |> pubsub.selecting(sub, fn(message) { message })

  pubsub.broadcast(pubsub_instance, "room:lobby", "a", "one")
  pubsub.broadcast(pubsub_instance, "room:private", "b", "two")

  let assert Ok(first) = process.selector_receive(from: selector, within: 100)
  let assert Ok(second) = process.selector_receive(from: selector, within: 100)

  [first.topic, second.topic]
  |> should.equal(["room:lobby", "room:private"])
  [first.payload, second.payload]
  |> should.equal(["one", "two"])

  // Cleanup
  pubsub.leave(sub, "room:lobby")
  pubsub.leave(sub, "room:private")
}
