import beryl
import beryl/socket
import beryl/topic
import beryl/wire
import gleam/json
import gleam/option
import gleam/set
import gleam/string
import gleeunit
import gleeunit/should

// Test helper: create a mock transport
fn mock_transport() -> socket.Transport {
  socket.Transport(
    send_text: fn(_) { Ok(Nil) },
    send_binary: fn(_) { Ok(Nil) },
    close: fn() { Ok(Nil) },
  )
}

pub fn main() {
  gleeunit.main()
}

// Topic pattern tests

pub fn parse_exact_pattern_test() {
  topic.parse_pattern("room:lobby")
  |> should.equal(topic.Exact("room:lobby"))
}

pub fn parse_wildcard_pattern_test() {
  topic.parse_pattern("room:*")
  |> should.equal(topic.Wildcard("room:"))
}

pub fn wildcard_matches_test() {
  let pattern = topic.Wildcard("room:")

  topic.matches(pattern, "room:lobby")
  |> should.be_true

  topic.matches(pattern, "room:123")
  |> should.be_true

  topic.matches(pattern, "user:123")
  |> should.be_false
}

pub fn exact_matches_test() {
  let pattern = topic.Exact("room:lobby")

  topic.matches(pattern, "room:lobby")
  |> should.be_true

  topic.matches(pattern, "room:other")
  |> should.be_false
}

pub fn extract_id_test() {
  let pattern = topic.Wildcard("room:")

  topic.extract_id(pattern, "room:lobby")
  |> should.equal(Ok("lobby"))

  topic.extract_id(pattern, "room:abc:123")
  |> should.equal(Ok("abc:123"))

  topic.extract_id(topic.Exact("room:lobby"), "room:lobby")
  |> should.equal(Error(Nil))
}

pub fn segments_test() {
  topic.segments("room:lobby")
  |> should.equal(["room", "lobby"])

  topic.segments("doc:tenant:123:ops")
  |> should.equal(["doc", "tenant", "123", "ops"])
}

pub fn from_segments_test() {
  topic.from_segments(["room", "lobby"])
  |> should.equal("room:lobby")
}

pub fn validate_topic_test() {
  topic.validate("room:lobby")
  |> should.equal(Ok("room:lobby"))

  topic.validate("")
  |> should.equal(Error(topic.EmptyTopic))

  topic.validate(":invalid")
  |> should.be_error

  topic.validate("invalid:")
  |> should.be_error
}

// Config tests

pub fn default_config_test() {
  let config = beryl.default_config()

  config.heartbeat_interval_ms
  |> should.equal(30_000)

  config.heartbeat_timeout_ms
  |> should.equal(60_000)
}

// Wire protocol tests

pub fn decode_valid_message_test() {
  let result =
    wire.decode_message("[\"j1\",\"r1\",\"room:lobby\",\"phx_join\",{}]")

  result |> should.be_ok

  let assert Ok(msg) = result
  msg.join_ref |> should.equal(option.Some("j1"))
  msg.ref |> should.equal(option.Some("r1"))
  msg.topic |> should.equal("room:lobby")
  msg.event |> should.equal("phx_join")
}

pub fn decode_message_with_null_refs_test() {
  let assert Ok(msg) =
    wire.decode_message("[null,\"ref\",\"topic\",\"event\",{}]")

  msg.join_ref |> should.equal(option.None)
  msg.ref |> should.equal(option.Some("ref"))
  msg.topic |> should.equal("topic")
  msg.event |> should.equal("event")
}

pub fn decode_message_both_refs_null_test() {
  let assert Ok(msg) =
    wire.decode_message(
      "[null,null,\"room:lobby\",\"new_msg\",{\"text\":\"hi\"}]",
    )

  msg.join_ref |> should.equal(option.None)
  msg.ref |> should.equal(option.None)
  msg.topic |> should.equal("room:lobby")
  msg.event |> should.equal("new_msg")
}

pub fn decode_invalid_json_test() {
  wire.decode_message("not json at all")
  |> should.be_error
}

pub fn decode_empty_string_test() {
  wire.decode_message("")
  |> should.be_error
}

pub fn decode_wrong_format_object_test() {
  wire.decode_message("{\"topic\": \"room\"}")
  |> should.be_error
}

pub fn decode_wrong_format_short_array_test() {
  wire.decode_message("[1,2,3]")
  |> should.be_error
}

pub fn encode_roundtrip_test() {
  // Decode a message then re-encode it
  let original = "[\"j1\",\"r1\",\"room:lobby\",\"msg\",\"hello\"]"
  let assert Ok(msg) = wire.decode_message(original)

  let encoded = wire.encode(msg)
  encoded |> string.contains("room:lobby") |> should.be_true
  encoded |> string.contains("msg") |> should.be_true
  encoded |> string.contains("hello") |> should.be_true
}

pub fn encode_with_object_payload_roundtrip_test() {
  let original =
    "[null,\"ref1\",\"chat:general\",\"typing\",{\"user\":\"alice\"}]"
  let assert Ok(msg) = wire.decode_message(original)

  let encoded = wire.encode(msg)
  encoded |> string.contains("chat:general") |> should.be_true
  encoded |> string.contains("typing") |> should.be_true
  encoded |> string.contains("alice") |> should.be_true
}

pub fn reply_json_ok_test() {
  let reply =
    wire.reply_json(
      option.Some("j1"),
      "ref1",
      "room:lobby",
      wire.StatusOk,
      json.object([]),
    )

  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reply |> string.contains("room:lobby") |> should.be_true
}

pub fn reply_json_error_test() {
  let reply =
    wire.reply_json(
      option.None,
      "ref1",
      "room:lobby",
      wire.StatusError,
      json.object([#("reason", json.string("unauthorized"))]),
    )

  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("unauthorized") |> should.be_true
}

pub fn push_message_test() {
  let msg = wire.push("room:lobby", "new_message", json.string("content"))

  msg |> string.contains("room:lobby") |> should.be_true
  msg |> string.contains("new_message") |> should.be_true
  // Push messages have null for join_ref and ref
  msg |> string.starts_with("[null,null,") |> should.be_true
}

pub fn heartbeat_reply_test() {
  let reply = wire.heartbeat_reply("hb-123")

  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("phoenix") |> should.be_true
  reply |> string.contains("hb-123") |> should.be_true
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn is_system_event_phx_join_test() {
  wire.is_system_event("phx_join") |> should.be_true
}

pub fn is_system_event_phx_leave_test() {
  wire.is_system_event("phx_leave") |> should.be_true
}

pub fn is_system_event_phx_reply_test() {
  wire.is_system_event("phx_reply") |> should.be_true
}

pub fn is_system_event_phx_error_test() {
  wire.is_system_event("phx_error") |> should.be_true
}

pub fn is_system_event_phx_close_test() {
  wire.is_system_event("phx_close") |> should.be_true
}

pub fn is_system_event_heartbeat_test() {
  wire.is_system_event("heartbeat") |> should.be_true
}

pub fn is_system_event_custom_test() {
  wire.is_system_event("new_message") |> should.be_false
  wire.is_system_event("typing") |> should.be_false
  wire.is_system_event("presence_diff") |> should.be_false
}

pub fn format_decode_error_invalid_json_test() {
  wire.format_decode_error(wire.InvalidJson("bad input"))
  |> string.contains("Invalid JSON")
  |> should.be_true
}

pub fn format_decode_error_invalid_format_test() {
  wire.format_decode_error(wire.InvalidFormat("wrong structure"))
  |> string.contains("Invalid format")
  |> should.be_true
}

pub fn format_decode_error_missing_field_test() {
  wire.format_decode_error(wire.MissingField("topic"))
  |> string.contains("Missing required field")
  |> should.be_true
}

// Socket tests

pub fn socket_new_and_id_test() {
  let s = socket.new("socket-123", "initial-assigns", mock_transport())

  socket.id(s) |> should.equal("socket-123")
}

pub fn socket_get_assigns_test() {
  let s = socket.new("socket-1", "my-assigns", mock_transport())

  socket.get_assigns(s) |> should.equal("my-assigns")
}

pub fn socket_set_assigns_test() {
  let s = socket.new("socket-1", "initial", mock_transport())

  let s2 = socket.set_assigns(s, "updated")
  socket.get_assigns(s2) |> should.equal("updated")

  // Original socket unchanged (immutable)
  socket.get_assigns(s) |> should.equal("initial")
}

pub fn socket_set_assigns_different_value_test() {
  let s = socket.new("socket-1", 100, mock_transport())

  let s2 = socket.set_assigns(s, 200)
  let s3 = socket.set_assigns(s2, 300)

  socket.get_assigns(s) |> should.equal(100)
  socket.get_assigns(s2) |> should.equal(200)
  socket.get_assigns(s3) |> should.equal(300)
}

pub fn socket_map_assigns_test() {
  let s = socket.new("socket-1", 5, mock_transport())

  let s2 = socket.map_assigns(s, fn(x) { x * 2 })
  socket.get_assigns(s2) |> should.equal(10)
}

pub fn socket_map_assigns_type_change_test() {
  let s = socket.new("socket-1", 42, mock_transport())

  // Transform Int to String
  let s2 = socket.map_assigns(s, fn(x) { "value:" <> string.inspect(x) })
  socket.get_assigns(s2) |> should.equal("value:42")
}

pub fn socket_topics_initially_empty_test() {
  let s = socket.new("socket-1", Nil, mock_transport())

  socket.topics(s)
  |> should.equal(set.new())
}

pub fn socket_is_subscribed_false_initially_test() {
  let s = socket.new("socket-1", Nil, mock_transport())

  socket.is_subscribed(s, "room:lobby") |> should.be_false
  socket.is_subscribed(s, "chat:general") |> should.be_false
}

pub fn socket_add_topic_test() {
  let s = socket.new("socket-1", Nil, mock_transport())

  let s2 = socket.add_topic(s, "room:lobby")
  socket.is_subscribed(s2, "room:lobby") |> should.be_true
  socket.is_subscribed(s2, "room:other") |> should.be_false
}

pub fn socket_add_multiple_topics_test() {
  let s =
    socket.new("socket-1", Nil, mock_transport())
    |> socket.add_topic("room:lobby")
    |> socket.add_topic("room:private")
    |> socket.add_topic("notifications:user-1")

  socket.is_subscribed(s, "room:lobby") |> should.be_true
  socket.is_subscribed(s, "room:private") |> should.be_true
  socket.is_subscribed(s, "notifications:user-1") |> should.be_true
  socket.is_subscribed(s, "room:other") |> should.be_false
}

pub fn socket_remove_topic_test() {
  let s =
    socket.new("socket-1", Nil, mock_transport())
    |> socket.add_topic("room:lobby")
    |> socket.add_topic("room:private")

  let s2 = socket.remove_topic(s, "room:lobby")

  socket.is_subscribed(s2, "room:lobby") |> should.be_false
  socket.is_subscribed(s2, "room:private") |> should.be_true
}

pub fn socket_remove_nonexistent_topic_test() {
  let s = socket.new("socket-1", Nil, mock_transport())

  // Removing a topic that doesn't exist should be a no-op
  let s2 = socket.remove_topic(s, "room:never-joined")
  socket.is_subscribed(s2, "room:never-joined") |> should.be_false
}

pub fn socket_add_same_topic_twice_test() {
  let s =
    socket.new("socket-1", Nil, mock_transport())
    |> socket.add_topic("room:lobby")
    |> socket.add_topic("room:lobby")

  // Should still be subscribed, no duplicates in set
  socket.is_subscribed(s, "room:lobby") |> should.be_true
}

pub fn socket_id_preserved_after_mutations_test() {
  let s =
    socket.new("original-id", "assigns", mock_transport())
    |> socket.set_assigns("new-assigns")
    |> socket.add_topic("room:1")
    |> socket.add_topic("room:2")
    |> socket.remove_topic("room:1")

  socket.id(s) |> should.equal("original-id")
}
