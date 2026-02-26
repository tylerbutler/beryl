//// Topic - Pattern matching for channel routing
////
//// Topics are string identifiers that clients join (e.g., "room:lobby").
//// Patterns define how topics are routed to channel handlers.

import gleam/list
import gleam/string

/// Topic pattern for routing
pub type TopicPattern {
  /// Exact match: "room:lobby" only matches "room:lobby"
  Exact(String)
  /// Wildcard suffix: "room:*" matches "room:lobby", "room:123", etc.
  Wildcard(prefix: String)
}

/// Parse a pattern string into TopicPattern
///
/// ## Examples
///
/// ```gleam
/// parse_pattern("room:*") // -> Wildcard("room:")
/// parse_pattern("room:lobby") // -> Exact("room:lobby")
/// parse_pattern("doc:*:ops") // -> Exact("doc:*:ops") - only trailing * supported
/// ```
pub fn parse_pattern(pattern: String) -> TopicPattern {
  case string.ends_with(pattern, "*") {
    True -> {
      let prefix = string.drop_end(pattern, 1)
      Wildcard(prefix)
    }
    False -> Exact(pattern)
  }
}

/// Check if a topic matches a pattern
///
/// ## Examples
///
/// ```gleam
/// matches(Wildcard("room:"), "room:lobby") // -> True
/// matches(Wildcard("room:"), "user:123") // -> False
/// matches(Exact("room:lobby"), "room:lobby") // -> True
/// matches(Exact("room:lobby"), "room:other") // -> False
/// ```
pub fn matches(pattern: TopicPattern, topic: String) -> Bool {
  case pattern {
    Exact(p) -> p == topic
    Wildcard(prefix) -> string.starts_with(topic, prefix)
  }
}

/// Extract the wildcard portion from a topic
///
/// ## Examples
///
/// ```gleam
/// extract_id(Wildcard("room:"), "room:lobby") // -> Ok("lobby")
/// extract_id(Wildcard("doc:"), "doc:abc:123") // -> Ok("abc:123")
/// extract_id(Exact("room:lobby"), "room:lobby") // -> Error(Nil)
/// ```
pub fn extract_id(pattern: TopicPattern, topic: String) -> Result(String, Nil) {
  case pattern {
    Exact(_) -> Error(Nil)
    Wildcard(prefix) -> {
      case string.starts_with(topic, prefix) {
        True -> Ok(string.drop_start(topic, string.length(prefix)))
        False -> Error(Nil)
      }
    }
  }
}

/// Parse a topic into segments by splitting on ":"
///
/// ## Examples
///
/// ```gleam
/// segments("room:lobby") // -> ["room", "lobby"]
/// segments("doc:tenant:123:ops") // -> ["doc", "tenant", "123", "ops"]
/// ```
pub fn segments(topic: String) -> List(String) {
  string.split(topic, ":")
}

/// Get the first segment (namespace) of a topic
///
/// ## Examples
///
/// ```gleam
/// namespace("room:lobby") // -> Ok("room")
/// namespace("") // -> Error(Nil)
/// ```
pub fn namespace(topic: String) -> Result(String, Nil) {
  topic
  |> segments
  |> list.first
}

/// Build a topic from segments
///
/// ## Examples
///
/// ```gleam
/// from_segments(["room", "lobby"]) // -> "room:lobby"
/// from_segments(["doc", "tenant", "123"]) // -> "doc:tenant:123"
/// ```
pub fn from_segments(parts: List(String)) -> String {
  string.join(parts, ":")
}

/// Validate a topic string
///
/// Topics must:
/// - Not be empty
/// - Not contain control characters
/// - Not start or end with ":"
pub fn validate(topic: String) -> Result(String, TopicError) {
  case string.is_empty(topic) {
    True -> Error(EmptyTopic)
    False ->
      case string.starts_with(topic, ":") || string.ends_with(topic, ":") {
        True -> Error(InvalidFormat("topic cannot start or end with ':'"))
        False -> Ok(topic)
      }
  }
}

pub type TopicError {
  EmptyTopic
  InvalidFormat(String)
}
