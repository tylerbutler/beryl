import beryl
import beryl/channel
import beryl/coordinator
import beryl/error as beryl_error
import beryl/group
import beryl/socket
import beryl/topic
import beryl/wire
import beryl/wire/codec
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should

// Test helper: create a mock transport
fn mock_transport() -> socket.Transport {
  socket.new_transport(
    send_text: fn(_) { Ok(Nil) },
    send_binary: fn(_) { Ok(Nil) },
    close: fn() { Ok(Nil) },
  )
}

fn text_frame(frame: codec.Frame) -> String {
  let assert codec.TextFrame(text) = frame
  text
}

fn wait_until(predicate: fn() -> Bool, timeout_ms: Int, step_ms: Int) -> Nil {
  case predicate() || timeout_ms <= 0 {
    True -> Nil
    False -> {
      process.sleep(step_ms)
      wait_until(predicate, timeout_ms - step_ms, step_ms)
    }
  }
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

pub fn join_with_control_character_topic_gets_error_reply_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-ctrl-join",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  // Topic contains a newline — should be rejected before reaching the handler
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-ctrl-join",
    "[null,\"ref-1\",\"room:\\nlobby\",\"phx_join\",{}]",
  )

  let assert Ok(reply) = process.receive(sent_messages, 500)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
}

pub fn join_with_too_long_topic_gets_error_reply_test() {
  let long_topic = "room:" <> string.repeat("a", 300)
  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_topic_length(max_length: 64),
    )
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-long-topic",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  // Route a join with a topic longer than max_topic_length
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-long-topic",
    "[null,\"ref-2\",\"" <> long_topic <> "\",\"phx_join\",{}]",
  )

  let assert Ok(reply) = process.receive(sent_messages, 500)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
}

pub fn join_topic_over_byte_limit_but_under_grapheme_limit_gets_error_reply_test() {
  // 37 graphemes but 101 bytes: "room:" (5 bytes) + 32 × "€" (3 bytes each).
  // max_topic_length is a byte limit, so this must be rejected.
  let multibyte_topic = "room:" <> string.repeat("€", 32)
  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_topic_length(max_length: 64),
    )
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-multibyte-topic",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-multibyte-topic",
    "[null,\"ref-3\",\"" <> multibyte_topic <> "\",\"phx_join\",{}]",
  )

  let assert Ok(reply) = process.receive(sent_messages, 500)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("invalid_topic") |> should.be_true
}

pub fn event_over_byte_limit_but_under_grapheme_limit_is_dropped_test() {
  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_event_length(max_length: 16),
    )
  let sent_messages = process.new_subject()
  let handled_events = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-multibyte-event",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
    |> channel.with_handle_in(fn(event, _payload, socket) {
      process.send(handled_events, event)
      channel.NoReply(socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-multibyte-event",
    "[null,\"ref-1\",\"room:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_join_reply) = process.receive(sent_messages, 500)

  // 10 graphemes but 30 bytes: max_event_length is a byte limit, so this
  // event must be dropped before reaching handle_in.
  let oversized_event = string.repeat("€", 10)
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-multibyte-event",
    "[null,\"ref-2\",\"room:lobby\",\"" <> oversized_event <> "\",{}]",
  )
  // Sentinel event: the coordinator processes messages in order, so if the
  // oversized event were handled, it would arrive before "ping".
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-multibyte-event",
    "[null,\"ref-3\",\"room:lobby\",\"ping\",{}]",
  )

  let assert Ok(first_event) = process.receive(handled_events, 500)
  first_event |> should.equal("ping")
}

pub fn register_rejects_empty_pattern_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })

  let assert Error(beryl.InvalidPattern("")) =
    beryl.register(channels, "", handler)
}

pub fn register_rejects_control_character_pattern_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })

  let assert Error(beryl.InvalidPattern("room:\nlobby")) =
    beryl.register(channels, "room:\nlobby", handler)
}

pub fn register_accepts_bare_catch_all_pattern_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })

  let assert Ok(_) = beryl.register(channels, "*", handler)
}

pub fn socket_cannot_join_more_than_configured_topic_cap_test() {
  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_joined_topics_per_socket(max_topics: 1),
    )
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-join-cap",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-join-cap",
    "[null,\"ref-1\",\"room:one\",\"phx_join\",{}]",
  )
  let assert Ok(first_reply) = process.receive(sent_messages, 500)
  first_reply |> string.contains("\"status\":\"ok\"") |> should.be_true

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-join-cap",
    "[null,\"ref-2\",\"room:two\",\"phx_join\",{}]",
  )
  let assert Ok(second_reply) = process.receive(sent_messages, 500)
  second_reply |> string.contains("too_many_topics") |> should.be_true
}

pub fn segment_wildcard_registered_channel_routes_matching_topic_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "segment-socket",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
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

  let assert Ok(_) = beryl.register(channels, "document:*:ops", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
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
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "segment-reject-socket",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  let handler =
    channel.new(fn(_topic_name, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })

  let assert Ok(_) = beryl.register(channels, "document:*:ops", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "segment-reject-socket",
    "[null,\"join-ref\",\"document:tenant-a:view\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("no_channel_handler") |> should.be_true
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

pub fn send_info_routes_message_to_joined_channel_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-info",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
    |> channel.with_handle_info(fn(message: String, socket) {
      case message {
        "notify" ->
          channel.Push(
            "server_notify",
            json.object([#("ok", json.bool(True))]),
            socket,
          )
        _ -> channel.NoReply(socket)
      }
    })

  let assert Ok(registered) = beryl.register(channels, "room:*", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-info",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  beryl.send_info(registered, "socket-info", "room:lobby", "notify")

  let assert Ok(push) = process.receive(sent_messages, 500)
  push |> string.contains("server_notify") |> should.be_true
  push |> string.contains("\"ok\":true") |> should.be_true
}

/// Custom info-message type proving `handle_info` is type-safe end to end:
/// the handler matches on this type directly, with no `Dynamic` decode and no
/// unsafe FFI cast in application code.
type Notification {
  Notify(text: String)
  Silence
}

pub fn send_info_typed_message_round_trips_without_cast_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-typed-info",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
    |> channel.with_handle_info(fn(message: Notification, socket) {
      // No decode.run, no identity FFI cast — match on the typed value.
      case message {
        Notify(text) ->
          channel.Push(
            "server_notify",
            json.object([#("text", json.string(text))]),
            socket,
          )
        Silence -> channel.NoReply(socket)
      }
    })

  let assert Ok(registered) = beryl.register(channels, "room:*", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-typed-info",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  beryl.send_info(
    registered,
    "socket-typed-info",
    "room:lobby",
    Notify("hello"),
  )

  let assert Ok(push) = process.receive(sent_messages, 500)
  push |> string.contains("server_notify") |> should.be_true
  push |> string.contains("hello") |> should.be_true
}

pub fn send_info_reply_result_pushes_message_to_client_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-info-reply",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
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

  let assert Ok(registered) = beryl.register(channels, "room:*", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-info-reply",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  beryl.send_info(registered, "socket-info-reply", "room:lobby", "reply")

  let assert Ok(push) = process.receive(sent_messages, 500)
  push |> string.contains("server_reply") |> should.be_true
  push |> string.contains("\"ok\":true") |> should.be_true
}

// Connect-hook (on_connect) assigns seeding tests

pub fn connect_assigns_visible_in_channel_join_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  // Seed socket-level assigns as if produced by the transport on_connect hook.
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "auth-socket",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.string("alice"),
    ),
  )

  // The channel's assigns type is the seeded user id (String). The join
  // handler reads it from the socket instead of re-authenticating.
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      let user_id = socket.get_assigns(socket)
      let reply = json.object([#("user", json.string(user_id))])
      channel.JoinOk(reply: option.Some(reply), socket: socket)
    })

  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "auth-socket",
    "[null,\"join-ref\",\"room:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true
  join_reply |> string.contains("\"user\":\"alice\"") |> should.be_true
}

// Assigns updated by one callback must be visible to the next callback on
// the same socket/topic: the coordinator threads channel state between
// dispatches.
pub fn assigns_threaded_across_handle_in_calls_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let sent_messages = process.new_subject()

  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "counter-socket",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )

  // Counter channel: assigns hold an Int incremented on every "incr".
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket.set_assigns(socket, 0))
    })
    |> channel.with_handle_in(fn(_event, _payload, socket) {
      let count = socket.get_assigns(socket) + 1
      channel.Reply(
        "count",
        json.object([#("count", json.int(count))]),
        socket.set_assigns(socket, count),
      )
    })

  let assert Ok(_) = beryl.register(channels, "counter:*", handler)

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "counter-socket",
    "[\"j1\",\"r1\",\"counter:1\",\"phx_join\",{}]",
  )
  let assert Ok(join_reply) = process.receive(sent_messages, 500)
  join_reply |> string.contains("phx_reply") |> should.be_true

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "counter-socket",
    "[\"j1\",\"r2\",\"counter:1\",\"incr\",{}]",
  )
  let assert Ok(first) = process.receive(sent_messages, 500)
  first |> string.contains("\"count\":1") |> should.be_true

  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "counter-socket",
    "[\"j1\",\"r3\",\"counter:1\",\"incr\",{}]",
  )
  let assert Ok(second) = process.receive(sent_messages, 500)
  second |> string.contains("\"count\":2") |> should.be_true
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

pub fn channels_handle_remains_usable_after_start_test() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))

  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })

  let assert Ok(_) = beryl.register(channels, "opaque:*", handler)
}

pub fn stop_shuts_down_unsupervised_coordinator_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_connections_per_ip(max_connections: 1)
    |> beryl.with_message_rate(per_second: 10, burst: 10)
    |> beryl.with_join_rate(per_second: 10, burst: 10)
    |> beryl.with_channel_rate(per_second: 10, burst: 10)
  let assert Ok(channels) = beryl.start(config)
  let assert Ok(coordinator_pid) =
    process.subject_owner(beryl.coordinator_subject(channels))
  let sent_messages = process.new_subject()
  let terminated = process.new_subject()
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: option.None, socket: socket)
    })
    |> channel.with_terminate(fn(reason, _socket) {
      process.send(terminated, reason)
    })

  process.is_alive(coordinator_pid) |> should.be_true
  let assert Ok(_) = beryl.register(channels, "stop:*", handler)
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      "socket-stop",
      fn(text) {
        process.send(sent_messages, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      option.None,
      dynamic.nil(),
    ),
  )
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    "socket-stop",
    "[null,\"ref-stop\",\"stop:lobby\",\"phx_join\",{}]",
  )
  let assert Ok(_) = process.receive(sent_messages, 500)

  beryl.stop(channels)
  let assert Ok(reason) = process.receive(terminated, 500)
  reason |> should.equal(channel.Shutdown)
  wait_until(fn() { !process.is_alive(coordinator_pid) }, 1000, 10)

  process.is_alive(coordinator_pid) |> should.be_false
  beryl.stop(channels)
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
