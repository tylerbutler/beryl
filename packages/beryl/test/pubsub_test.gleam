import beryl/pubsub
import gleam/erlang/process
import gleeunit
import gleeunit/should

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

  pubsub.subscribe(ps, "room:lobby")
  pubsub.subscriber_count(ps, "room:lobby") |> should.equal(1)

  // Cleanup
  pubsub.unsubscribe(ps, "room:lobby")
}

pub fn pubsub_unsubscribe_test() {
  let config = pubsub.config_with_scope("test_pubsub_unsub")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  pubsub.subscribe(ps, "room:lobby")
  pubsub.subscriber_count(ps, "room:lobby") |> should.equal(1)

  pubsub.unsubscribe(ps, "room:lobby")
  pubsub.subscriber_count(ps, "room:lobby") |> should.equal(0)
}

pub fn pubsub_subscribers_returns_pids_test() {
  let config = pubsub.config_with_scope("test_pubsub_pids")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  pubsub.subscribe(ps, "room:lobby")
  let subs = pubsub.subscribers(ps, "room:lobby")
  should.equal(subs, [process.self()])

  // Cleanup
  pubsub.unsubscribe(ps, "room:lobby")
}

pub fn pubsub_broadcast_delivers_message_test() {
  let config = pubsub.config_with_scope("test_pubsub_bcast")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  pubsub.subscribe(ps, "room:lobby")

  pubsub.broadcast(ps, "room:lobby", "new_msg", "hello")

  let selector =
    process.new_selector()
    |> pubsub.selecting(fn(msg) { msg })

  let assert Ok(message) = process.selector_receive(from: selector, within: 100)
  message.topic |> should.equal("room:lobby")
  message.event |> should.equal("new_msg")
  message.payload |> should.equal("hello")
  message.from |> should.equal(pubsub.System)

  // Cleanup
  pubsub.unsubscribe(ps, "room:lobby")
}

pub fn pubsub_broadcast_from_excludes_sender_test() {
  let config = pubsub.config_with_scope("test_pubsub_bcast_from")
  let ps: pubsub.PubSub(String) = pubsub.start(config)

  pubsub.subscribe(ps, "room:lobby")

  // Broadcast from self - should NOT receive it
  pubsub.broadcast_from(ps, process.self(), "room:lobby", "typing", "")

  let selector =
    process.new_selector()
    |> pubsub.selecting(fn(msg) { msg })

  // Should time out since we excluded ourselves
  let result = process.selector_receive(from: selector, within: 50)
  should.be_error(result)

  // Cleanup
  pubsub.unsubscribe(ps, "room:lobby")
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

  pubsub.subscribe(ps, "room:lobby")
  pubsub.subscribe(ps, "room:private")

  pubsub.subscriber_count(ps, "room:lobby") |> should.equal(1)
  pubsub.subscriber_count(ps, "room:private") |> should.equal(1)

  // Cleanup
  pubsub.unsubscribe(ps, "room:lobby")
  pubsub.unsubscribe(ps, "room:private")
}
