import beryl/pubsub
import gleam/erlang/process
import gleeunit
import gleeunit/should

@external(erlang, "beryl_pubsub_test_ffi", "is_raw_wire_message")
fn is_raw_wire_message(
  topic: String,
  event: String,
  payload: String,
  timeout: Int,
) -> Bool

pub fn main() {
  gleeunit.main()
}

pub fn pubsub_start_test() {
  let config = pubsub.config_with_scope("test_pubsub_start")
  let _ps: pubsub.PubSub(String) = pubsub.start(config)
  should.be_true(True)
}

pub fn pubsub_start_default_config_test() {
  let _ps: pubsub.PubSub(String) = pubsub.start(pubsub.default_config())
  should.be_true(True)
}

pub fn pubsub_subscribe_and_count_test() {
  let config = pubsub.config_with_scope("test_pubsub_sub")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, "room:lobby")
  pubsub.subscriber_count(ps, "room:lobby") |> should.equal(1)

  // Cleanup
  pubsub.leave(sub, "room:lobby")
}

pub fn pubsub_unsubscribe_test() {
  let config = pubsub.config_with_scope("test_pubsub_unsub")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, "room:lobby")
  pubsub.subscriber_count(ps, "room:lobby") |> should.equal(1)

  pubsub.leave(sub, "room:lobby")
  pubsub.subscriber_count(ps, "room:lobby") |> should.equal(0)
}

pub fn pubsub_subscribers_returns_pids_test() {
  let config = pubsub.config_with_scope("test_pubsub_pids")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, "room:lobby")
  let subs = pubsub.subscribers(ps, "room:lobby")
  should.equal(subs, [process.self()])

  // Cleanup
  pubsub.leave(sub, "room:lobby")
}

pub fn pubsub_broadcast_delivers_message_test() {
  let config = pubsub.config_with_scope("test_pubsub_bcast")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, "room:lobby")

  pubsub.broadcast(ps, "room:lobby", "new_msg", "hello")

  let selector =
    process.new_selector()
    |> pubsub.selecting(sub, fn(msg) { msg })

  let assert Ok(message) = process.selector_receive(from: selector, within: 100)
  message.topic |> should.equal("room:lobby")
  message.event |> should.equal("new_msg")
  message.payload |> should.equal("hello")
  message.from |> should.equal(pubsub.System)

  // Cleanup
  pubsub.leave(sub, "room:lobby")
}

pub fn pubsub_broadcast_preserves_raw_wire_shape_test() {
  let config = pubsub.config_with_scope("test_pubsub_raw_wire_shape")
  let ps: pubsub.PubSub(String) = pubsub.start(config)
  let topic = "wire:raw"
  let event = "shape"
  let payload = "four-fields"

  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, topic)
  pubsub.broadcast(ps, topic, event, payload)

  is_raw_wire_message(topic, event, payload, 100)
  |> should.be_true

  pubsub.leave(sub, topic)
}

pub fn pubsub_broadcast_from_excludes_sender_test() {
  let config = pubsub.config_with_scope("test_pubsub_bcast_from")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, "room:lobby")

  // Broadcast from self - should NOT receive it
  pubsub.broadcast_from(ps, process.self(), "room:lobby", "typing", "")

  let selector =
    process.new_selector()
    |> pubsub.selecting(sub, fn(msg) { msg })

  // Should time out since we excluded ourselves
  let result = process.selector_receive(from: selector, within: 50)
  should.be_error(result)

  // Cleanup
  pubsub.leave(sub, "room:lobby")
}

pub fn pubsub_no_subscribers_is_noop_test() {
  let config = pubsub.config_with_scope("test_pubsub_nosubs")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  // Broadcast to topic with no subscribers - should not crash
  pubsub.broadcast(ps, "room:empty", "event", "")
  pubsub.subscriber_count(ps, "room:empty") |> should.equal(0)
}

pub fn pubsub_multiple_topics_test() {
  let config = pubsub.config_with_scope("test_pubsub_multi")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, "room:lobby")
  pubsub.join(sub, "room:private")

  pubsub.subscriber_count(ps, "room:lobby") |> should.equal(1)
  pubsub.subscriber_count(ps, "room:private") |> should.equal(1)

  // Cleanup
  pubsub.leave(sub, "room:lobby")
  pubsub.leave(sub, "room:private")
}

pub fn pubsub_one_subscriber_receives_from_multiple_topics_test() {
  let config = pubsub.config_with_scope("test_pubsub_multi_recv")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  // A single subscriber joined to two topics receives both topics' messages
  // through its one typed subject — no per-topic subject bookkeeping.
  let sub = pubsub.subscriber(ps)
  pubsub.join(sub, "room:lobby")
  pubsub.join(sub, "room:private")

  let selector =
    process.new_selector()
    |> pubsub.selecting(sub, fn(msg) { msg })

  pubsub.broadcast(ps, "room:lobby", "a", "one")
  pubsub.broadcast(ps, "room:private", "b", "two")

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
