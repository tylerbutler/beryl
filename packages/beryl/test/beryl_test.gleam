import beryl
import beryl/error as beryl_error
import beryl/event
import beryl/group
import beryl/topic
import beryl/wire
import beryl/wire/codec
import gleam/json
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should

fn text_frame(frame: codec.Frame) -> String {
  let assert codec.TextFrame(text) = frame
  text
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

pub fn parse_mid_segment_wildcard_pattern_test() {
  topic.parse_pattern("document:*:ops")
  |> should.equal(topic.SegmentWildcard(["document", "*", "ops"]))
}

pub fn parse_multi_segment_wildcard_pattern_test() {
  topic.parse_pattern("document:*:*")
  |> should.equal(topic.SegmentWildcard(["document", "*", "*"]))
}

pub fn single_trailing_wildcard_keeps_prefix_pattern_test() {
  topic.parse_pattern("document:tenant-a:*")
  |> should.equal(topic.Wildcard("document:tenant-a:"))
}

pub fn validate_pattern_rejects_empty_test() {
  topic.validate_pattern("")
  |> should.equal(Error(topic.EmptyTopic))
}

pub fn validate_pattern_rejects_control_characters_test() {
  topic.validate_pattern("room:\u{0001}*")
  |> should.equal(
    Error(topic.InvalidFormat("pattern contains control characters")),
  )

  topic.validate_pattern("room:\nlobby")
  |> should.equal(
    Error(topic.InvalidFormat("pattern contains control characters")),
  )
}

pub fn validate_pattern_accepts_valid_patterns_test() {
  topic.validate_pattern("room:lobby")
  |> should.equal(Ok("room:lobby"))

  topic.validate_pattern("room:*")
  |> should.equal(Ok("room:*"))

  topic.validate_pattern("document:*:ops")
  |> should.equal(Ok("document:*:ops"))
}

pub fn validate_pattern_accepts_bare_catch_all_test() {
  // A bare "*" is a documented catch-all matching every topic.
  topic.validate_pattern("*")
  |> should.equal(Ok("*"))

  topic.parse_pattern("*")
  |> should.equal(topic.Wildcard(""))
}

pub fn segment_wildcard_matches_same_shape_topics_test() {
  let pattern = topic.parse_pattern("document:*:ops")

  topic.matches(pattern, "document:tenant-a:ops")
  |> should.be_true

  topic.matches(pattern, "document:tenant-b:ops")
  |> should.be_true

  topic.matches(pattern, "document:tenant-a:view")
  |> should.be_false

  topic.matches(pattern, "document:tenant-a:doc-1:ops")
  |> should.be_false
}

pub fn tenant_trailing_wildcard_matches_documents_test() {
  let pattern = topic.parse_pattern("document:tenant-a:*")

  topic.matches(pattern, "document:tenant-a:doc-1")
  |> should.be_true

  topic.matches(pattern, "document:tenant-a:doc-1:ops")
  |> should.be_true

  topic.matches(pattern, "document:tenant-b:doc-1")
  |> should.be_false
}

pub fn extract_wildcards_from_segment_pattern_test() {
  let pattern = topic.parse_pattern("document:*:*")

  topic.extract_wildcards(pattern, "document:tenant-a:doc-42")
  |> should.equal(Ok(["tenant-a", "doc-42"]))

  topic.extract_wildcards(pattern, "document:tenant-a")
  |> should.equal(Error(topic.TopicMismatch))
}

pub fn extract_id_from_single_segment_wildcard_test() {
  let pattern = topic.parse_pattern("document:*:ops")

  topic.extract_id(pattern, "document:tenant-a:ops")
  |> should.equal(Ok("tenant-a"))

  topic.extract_id(
    topic.parse_pattern("document:*:*"),
    "document:tenant-a:doc-42",
  )
  |> should.equal(Error(topic.ExpectedOneWildcard(2)))
}

pub fn extract_id_test() {
  let pattern = topic.Wildcard("room:")

  topic.extract_id(pattern, "room:lobby")
  |> should.equal(Ok("lobby"))

  topic.extract_id(pattern, "room:abc:123")
  |> should.equal(Ok("abc:123"))

  topic.extract_id(topic.Exact("room:lobby"), "room:lobby")
  |> should.equal(Error(topic.NoWildcard))
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

pub fn validate_topic_rejects_control_characters_test() {
  // Newline
  topic.validate("room:\nlobby")
  |> should.be_error

  // Tab
  topic.validate("room:\tlobby")
  |> should.be_error

  // Null byte
  topic.validate("room:\u{0000}lobby")
  |> should.be_error

  // DEL (127)
  topic.validate("room:\u{007F}lobby")
  |> should.be_error

  // Control char at start
  topic.validate("\u{0001}room:lobby")
  |> should.be_error
}

pub fn validate_event_test() {
  topic.validate_event("new_message")
  |> should.equal(Ok("new_message"))

  topic.validate_event("phx_join")
  |> should.equal(Ok("phx_join"))

  topic.validate_event("")
  |> should.be_error

  topic.validate_event("event\ninjection")
  |> should.be_error

  topic.validate_event("event\u{0000}null")
  |> should.be_error
}

pub fn sanitize_for_log_test() {
  topic.sanitize_for_log("room:lobby")
  |> should.equal("room:lobby")

  topic.sanitize_for_log("room:\nlobby")
  |> should.equal("room:?lobby")

  topic.sanitize_for_log("room:\tlobby")
  |> should.equal("room:?lobby")

  topic.sanitize_for_log("room:\u{007F}lobby")
  |> should.equal("room:?lobby")

  topic.sanitize_for_log("")
  |> should.equal("")
}

// Config tests

pub fn default_config_test() {
  let config = beryl.config(wire.phoenix_codec())

  beryl.config_heartbeat_interval_ms(config)
  |> should.equal(30_000)

  beryl.config_heartbeat_timeout_ms(config)
  |> should.equal(60_000)

  beryl.config_max_connections_per_ip(config)
  |> should.equal(0)
}

pub fn with_heartbeat_sets_interval_and_timeout_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_heartbeat(interval_ms: 5000, timeout_ms: 10_000)

  beryl.config_heartbeat_interval_ms(config)
  |> should.equal(5000)

  beryl.config_heartbeat_timeout_ms(config)
  |> should.equal(10_000)
}

pub fn with_max_connections_per_ip_sets_limit_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_connections_per_ip(max_connections: 5)

  beryl.config_max_connections_per_ip(config)
  |> should.equal(5)
}

// Wire protocol tests

pub fn decode_valid_message_test() {
  let result =
    wire.decode_message("[\"j1\",\"r1\",\"room:lobby\",\"phx_join\",{}]")

  result |> should.be_ok

  let assert Ok(msg) = result
  codec.inbound_join_ref(msg) |> should.equal(option.Some("j1"))
  codec.inbound_ref(msg) |> should.equal(option.Some("r1"))
  codec.inbound_topic(msg) |> should.equal("room:lobby")
  codec.inbound_kind(msg) |> should.equal(codec.Join)
}

pub fn decode_message_with_null_refs_test() {
  let assert Ok(msg) =
    wire.decode_message("[null,\"ref\",\"topic\",\"event\",{}]")

  codec.inbound_join_ref(msg) |> should.equal(option.None)
  codec.inbound_ref(msg) |> should.equal(option.Some("ref"))
  codec.inbound_topic(msg) |> should.equal("topic")
  codec.inbound_kind(msg) |> should.equal(codec.Event("event"))
}

pub fn decode_message_both_refs_null_test() {
  let assert Ok(msg) =
    wire.decode_message(
      "[null,null,\"room:lobby\",\"new_msg\",{\"text\":\"hi\"}]",
    )

  codec.inbound_join_ref(msg) |> should.equal(option.None)
  codec.inbound_ref(msg) |> should.equal(option.None)
  codec.inbound_topic(msg) |> should.equal("room:lobby")
  codec.inbound_kind(msg) |> should.equal(codec.Event("new_msg"))
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
      option.Some("ref1"),
      "room:lobby",
      codec.StatusOk,
      json.object([]),
    )

  text_frame(reply) |> string.contains("phx_reply") |> should.be_true
  text_frame(reply) |> string.contains("\"status\":\"ok\"") |> should.be_true
  text_frame(reply) |> string.contains("room:lobby") |> should.be_true
}

pub fn reply_json_error_test() {
  let reply =
    wire.reply_json(
      option.None,
      option.Some("ref1"),
      "room:lobby",
      codec.StatusError,
      json.object([#("reason", json.string("unauthorized"))]),
    )

  text_frame(reply) |> string.contains("\"status\":\"error\"") |> should.be_true
  text_frame(reply) |> string.contains("unauthorized") |> should.be_true
}

pub fn push_message_test() {
  let msg = wire.push("room:lobby", "new_message", json.string("content"))

  text_frame(msg) |> string.contains("room:lobby") |> should.be_true
  text_frame(msg) |> string.contains("new_message") |> should.be_true
  // Push messages have null for join_ref and ref
  text_frame(msg) |> string.starts_with("[null,null,") |> should.be_true
}

pub fn heartbeat_reply_test() {
  let reply = wire.heartbeat_reply(option.Some("hb-123"))

  text_frame(reply) |> string.contains("phx_reply") |> should.be_true
  text_frame(reply) |> string.contains("phoenix") |> should.be_true
  text_frame(reply) |> string.contains("hb-123") |> should.be_true
  text_frame(reply) |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn format_decode_error_invalid_json_test() {
  wire.format_decode_error(codec.InvalidJson("bad input"))
  |> string.contains("Invalid JSON")
  |> should.be_true
}

pub fn format_decode_error_invalid_format_test() {
  wire.format_decode_error(codec.InvalidFormat("wrong structure"))
  |> string.contains("Invalid format")
  |> should.be_true
}

pub fn format_decode_error_missing_field_test() {
  wire.format_decode_error(codec.MissingField("topic"))
  |> string.contains("Missing required field")
  |> should.be_true
}

// Public config builder and topic helper coverage

pub fn with_join_rate_sets_fields_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_join_rate(per_second: 5, burst: 10)

  beryl.config_join_rate(cfg) |> should.equal(5)
  beryl.config_join_burst(cfg) |> should.equal(10)
}

pub fn with_channel_rate_sets_fields_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_channel_rate(per_second: 7, burst: 14)

  beryl.config_channel_rate(cfg) |> should.equal(7)
  beryl.config_channel_burst(cfg) |> should.equal(14)
}

pub fn channel_rate_max_keys_defaults_to_1000_test() {
  let cfg = beryl.config(wire.phoenix_codec())

  beryl.config_channel_rate_max_keys_per_socket(cfg) |> should.equal(1000)
}

pub fn with_channel_rate_max_keys_per_socket_sets_field_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_channel_rate_max_keys_per_socket(max_keys: 42)

  beryl.config_channel_rate_max_keys_per_socket(cfg) |> should.equal(42)
}

pub fn default_max_topic_length_is_256_test() {
  let cfg = beryl.config(wire.phoenix_codec())

  beryl.config_max_topic_length(cfg) |> should.equal(256)
}

pub fn with_max_topic_length_sets_field_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_topic_length(max_length: 128)

  beryl.config_max_topic_length(cfg) |> should.equal(128)
}

pub fn default_max_event_length_is_64_test() {
  let cfg = beryl.config(wire.phoenix_codec())

  beryl.config_max_event_length(cfg) |> should.equal(64)
}

pub fn with_max_event_length_sets_field_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_event_length(max_length: 32)

  beryl.config_max_event_length(cfg) |> should.equal(32)
}

pub fn default_max_inbound_frame_bytes_is_1mb_test() {
  let cfg = beryl.config(wire.phoenix_codec())

  beryl.config_max_inbound_frame_bytes(cfg) |> should.equal(1_048_576)
}

pub fn with_max_inbound_frame_bytes_sets_field_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_inbound_frame_bytes(max_bytes: 4096)

  beryl.config_max_inbound_frame_bytes(cfg) |> should.equal(4096)
}

pub fn default_max_joined_topics_per_socket_is_1000_test() {
  let cfg = beryl.config(wire.phoenix_codec())

  beryl.config_max_joined_topics_per_socket(cfg) |> should.equal(1000)
}

pub fn with_max_joined_topics_per_socket_sets_field_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_joined_topics_per_socket(max_topics: 12)

  beryl.config_max_joined_topics_per_socket(cfg) |> should.equal(12)
}

pub fn start_failure_description_is_public_test() {
  let describe = beryl_error.describe_start_failure
  should.be_true(True)
  let _ = describe
}

pub fn topic_namespace_test() {
  topic.namespace("room:lobby") |> should.equal(Ok("room"))
  topic.namespace("doc:tenant:123") |> should.equal(Ok("doc"))
}

pub fn group_broadcast_is_fire_and_forget_test() {
  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: fn(_info) { #(Nil, []) },
      update: fn(model, _ev) { event.Next(model, []) },
    )
  let assert Ok(groups) = group.start()
  let assert Ok(Nil) = group.create(groups, "team:eng")
  let assert Ok(Nil) = group.add(groups, "team:eng", "room:lobby")

  // Broadcasting to a populated group returns Nil (fire and forget)
  group.broadcast(groups, channels, "team:eng", "announce", json.object([]))
  |> should.equal(Nil)

  // Broadcasting to a missing group is a silent no-op
  group.broadcast(groups, channels, "missing", "announce", json.object([]))
  |> should.equal(Nil)
}
