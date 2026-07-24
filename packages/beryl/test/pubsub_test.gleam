import beryl/pubsub
import gleam/erlang/process
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn pubsub_start_test() {
  let config = pubsub.config_with_scope("test_pubsub_start")
  let bus: pubsub.PubSub(String) = pubsub.start(config)
  // A fresh scope has no subscribers for any topic.
  pubsub.subscriber_count(bus, "room:lobby") |> should.equal(0)
}

pub fn pubsub_start_default_config_test() {
  let bus: pubsub.PubSub(String) = pubsub.start(pubsub.default_config())
  pubsub.subscriber_count(bus, "room:lobby") |> should.equal(0)
}

pub fn pubsub_subscribe_and_count_test() {
  let config = pubsub.config_with_scope("test_pubsub_sub")
  let bus: pubsub.PubSub(String) = pubsub.start(config)

  let subscription = pubsub.subscriber(bus)
  pubsub.join(subscription, "room:lobby")
  pubsub.subscriber_count(bus, "room:lobby") |> should.equal(1)

  // Cleanup
  pubsub.leave(subscription, "room:lobby")
}

pub fn pubsub_unsubscribe_test() {
  let config = pubsub.config_with_scope("test_pubsub_unsub")
  let bus: pubsub.PubSub(String) = pubsub.start(config)

  let subscription = pubsub.subscriber(bus)
  pubsub.join(subscription, "room:lobby")
  pubsub.subscriber_count(bus, "room:lobby") |> should.equal(1)

  pubsub.leave(subscription, "room:lobby")
  pubsub.subscriber_count(bus, "room:lobby") |> should.equal(0)
}

pub fn pubsub_subscribers_returns_pids_test() {
  let config = pubsub.config_with_scope("test_pubsub_pids")
  let bus: pubsub.PubSub(String) = pubsub.start(config)

  let subscription = pubsub.subscriber(bus)
  pubsub.join(subscription, "room:lobby")
  let member_pids = pubsub.subscribers(bus, "room:lobby")
  should.equal(member_pids, [process.self()])

  // Cleanup
  pubsub.leave(subscription, "room:lobby")
}

pub fn pubsub_broadcast_delivers_message_test() {
  let config = pubsub.config_with_scope("test_pubsub_bcast")
  let bus: pubsub.PubSub(String) = pubsub.start(config)

  let subscription = pubsub.subscriber(bus)
  pubsub.join(subscription, "room:lobby")

  pubsub.broadcast(bus, "room:lobby", "new_msg", "hello")

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscription, fn(message) { message })

  let assert Ok(message) = process.selector_receive(from: selector, within: 100)
  message.topic |> should.equal("room:lobby")
  message.event |> should.equal("new_msg")
  message.payload |> should.equal("hello")
  message.from |> should.equal(pubsub.System)

  // Cleanup
  pubsub.leave(subscription, "room:lobby")
}

pub fn pubsub_broadcast_from_excludes_sender_test() {
  let config = pubsub.config_with_scope("test_pubsub_bcast_from")
  let bus: pubsub.PubSub(String) = pubsub.start(config)

  let subscription = pubsub.subscriber(bus)
  pubsub.join(subscription, "room:lobby")

  // Broadcast from self - should NOT receive it
  pubsub.broadcast_from(bus, process.self(), "room:lobby", "typing", "")

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscription, fn(message) { message })

  // Should time out since we excluded ourselves
  let result = process.selector_receive(from: selector, within: 50)
  should.be_error(result)

  // Cleanup
  pubsub.leave(subscription, "room:lobby")
}

pub fn pubsub_no_subscribers_is_noop_test() {
  let config = pubsub.config_with_scope("test_pubsub_nosubs")
  let bus: pubsub.PubSub(String) = pubsub.start(config)

  // Broadcast to topic with no subscribers - should not crash
  pubsub.broadcast(bus, "room:empty", "event", "")
  pubsub.subscriber_count(bus, "room:empty") |> should.equal(0)
}

pub fn pubsub_multiple_topics_test() {
  let config = pubsub.config_with_scope("test_pubsub_multi")
  let bus: pubsub.PubSub(String) = pubsub.start(config)

  let subscription = pubsub.subscriber(bus)
  pubsub.join(subscription, "room:lobby")
  pubsub.join(subscription, "room:private")

  pubsub.subscriber_count(bus, "room:lobby") |> should.equal(1)
  pubsub.subscriber_count(bus, "room:private") |> should.equal(1)

  // Cleanup
  pubsub.leave(subscription, "room:lobby")
  pubsub.leave(subscription, "room:private")
}

pub fn pubsub_one_subscriber_receives_from_multiple_topics_test() {
  let config = pubsub.config_with_scope("test_pubsub_multi_recv")
  let bus: pubsub.PubSub(String) = pubsub.start(config)

  // A single subscriber joined to two topics receives both topics' messages
  // through its one typed subject — no per-topic subject bookkeeping.
  let subscription = pubsub.subscriber(bus)
  pubsub.join(subscription, "room:lobby")
  pubsub.join(subscription, "room:private")

  let selector =
    process.new_selector()
    |> pubsub.selecting(subscription, fn(message) { message })

  pubsub.broadcast(bus, "room:lobby", "a", "one")
  pubsub.broadcast(bus, "room:private", "b", "two")

  let assert Ok(first) = process.selector_receive(from: selector, within: 100)
  let assert Ok(second) = process.selector_receive(from: selector, within: 100)

  [first.topic, second.topic]
  |> should.equal(["room:lobby", "room:private"])
  [first.payload, second.payload]
  |> should.equal(["one", "two"])

  // Cleanup
  pubsub.leave(subscription, "room:lobby")
  pubsub.leave(subscription, "room:private")
}
