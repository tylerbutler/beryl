import beryl
import beryl/channel
import beryl/coordinator
import beryl/group
import beryl/socket
import beryl/topic
import beryl/wire
import beryl/wire/codec
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option
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
  |> should.equal(Error(Nil))
}

pub fn extract_id_from_single_segment_wildcard_test() {
  let pattern = topic.parse_pattern("document:*:ops")

  topic.extract_id(pattern, "document:tenant-a:ops")
  |> should.equal(Ok("tenant-a"))

  topic.extract_id(
    topic.parse_pattern("document:*:*"),
    "document:tenant-a:doc-42",
  )
  |> should.equal(Error(Nil))
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

pub fn segment_wildcard_registered_channel_routes_matching_topic_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "segment-socket",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
    ),
  )

  let handler =
    channel.new(fn(topic_name, _payload, socket) {
      let assert Ok([tenant]) =
        topic.extract_wildcards(
          topic.parse_pattern("document:*:ops"),
          topic_name,
        )
      let reply = json.object([#("tenant", json.string(tenant))])
      channel.JoinOk(reply: option.Some(reply), socket: socket)
    })

  beryl.register(channels, "document:*:ops", handler)
  |> should.equal(Ok(Nil))

  coordinator.route_message(
    channels.coordinator,
    "segment-socket",
    "[null,\"join-ref\",\"document:tenant-a:ops\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true
  join_reply |> string.contains("\"tenant\":\"tenant-a\"") |> should.be_true
}

pub fn segment_wildcard_registered_channel_rejects_wrong_segment_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "segment-reject-socket",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
    ),
  )

  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })

  beryl.register(channels, "document:*:ops", handler)
  |> should.equal(Ok(Nil))

  coordinator.route_message(
    channels.coordinator,
    "segment-reject-socket",
    "[null,\"join-ref\",\"document:tenant-a:view\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("no_channel_handler") |> should.be_true
}

// Config tests

pub fn default_config_test() {
  let config = beryl.config(wire.phoenix_codec())

  config.heartbeat_interval_ms
  |> should.equal(30_000)

  config.heartbeat_timeout_ms
  |> should.equal(60_000)
}

pub fn send_info_routes_message_to_joined_channel_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "socket-info",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
    ),
  )

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
    |> channel.with_handle_info(fn(message, socket) {
      case decode.run(message, decode.string) {
        Ok("notify") ->
          channel.Push(
            "server_notify",
            json.object([#("ok", json.bool(True))]),
            socket,
          )
        _ -> channel.NoReply(socket)
      }
    })

  beryl.register(channels, "room:*", handler)
  |> should.equal(Ok(Nil))

  coordinator.route_message(
    channels.coordinator,
    "socket-info",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  beryl.send_info(channels, "socket-info", "room:lobby", "notify")

  let assert Ok(push) = process.receive(sent_messages, 500)
  push |> string.contains("server_notify") |> should.be_true
  push |> string.contains("\"ok\":true") |> should.be_true
}

pub fn send_info_reply_result_pushes_message_to_client_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      "socket-info-reply",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
    ),
  )

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
    |> channel.with_handle_info(fn(_message, socket) {
      channel.Reply(
        "server_reply",
        json.object([#("ok", json.bool(True))]),
        socket,
      )
    })

  beryl.register(channels, "room:*", handler)
  |> should.equal(Ok(Nil))

  coordinator.route_message(
    channels.coordinator,
    "socket-info-reply",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  beryl.send_info(channels, "socket-info-reply", "room:lobby", "reply")

  let assert Ok(push) = process.receive(sent_messages, 500)
  push |> string.contains("server_reply") |> should.be_true
  push |> string.contains("\"ok\":true") |> should.be_true
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
  msg.kind |> should.equal(codec.Join)
}

pub fn decode_message_with_null_refs_test() {
  let assert Ok(msg) =
    wire.decode_message("[null,\"ref\",\"topic\",\"event\",{}]")

  msg.join_ref |> should.equal(option.None)
  msg.ref |> should.equal(option.Some("ref"))
  msg.topic |> should.equal("topic")
  msg.kind |> should.equal(codec.Event("event"))
}

pub fn decode_message_both_refs_null_test() {
  let assert Ok(msg) =
    wire.decode_message(
      "[null,null,\"room:lobby\",\"new_msg\",{\"text\":\"hi\"}]",
    )

  msg.join_ref |> should.equal(option.None)
  msg.ref |> should.equal(option.None)
  msg.topic |> should.equal("room:lobby")
  msg.kind |> should.equal(codec.Event("new_msg"))
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
  let s2 = socket.map_assigns(s, fn(x) { "value:" <> int.to_string(x) })
  socket.get_assigns(s2) |> should.equal("value:42")
}

// Public config builder and topic helper coverage

pub fn with_join_rate_sets_fields_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_join_rate(per_second: 5, burst: 10)

  cfg.join_rate |> should.equal(5)
  cfg.join_burst |> should.equal(10)
}

pub fn with_channel_rate_sets_fields_test() {
  let cfg =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_channel_rate(per_second: 7, burst: 14)

  cfg.channel_rate |> should.equal(7)
  cfg.channel_burst |> should.equal(14)
}

pub fn extract_topic_id_test() {
  beryl.extract_topic_id(topic.Wildcard("room:"), "room:lobby")
  |> should.equal(Ok("lobby"))

  beryl.extract_topic_id(topic.Exact("room:lobby"), "room:lobby")
  |> should.equal(Error(Nil))
}

pub fn topic_namespace_test() {
  topic.namespace("room:lobby") |> should.equal(Ok("room"))
  topic.namespace("doc:tenant:123") |> should.equal(Ok("doc"))
}

pub fn group_broadcast_is_fire_and_forget_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
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
