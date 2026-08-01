//// Topic - Pattern matching for channel routing
////
//// Topics are string identifiers that clients join (e.g., "room:lobby").
//// Patterns define how topics are routed to channel handlers. Patterns can be
//// exact, prefix wildcards, or segment wildcards where "*" occupies a
//// complete colon-delimited segment.

import gleam/bool
import gleam/list
import gleam/result
import gleam/string

/// Topic pattern for routing
pub type TopicPattern {
  /// Exact match: "room:lobby" only matches "room:lobby"
  Exact(String)
  /// Prefix wildcard: "room:*" matches "room:lobby", "room:123", etc.
  Wildcard(prefix: String)
  /// Segment wildcard: "document:*:ops" matches the same number of ":"
  /// segments where "*" occupies one complete segment.
  SegmentWildcard(segments: List(String))
}

/// Parse a pattern string into TopicPattern
///
/// ## Examples
///
/// ```gleam
/// parse_pattern("room:*") // -> Wildcard("room:")
/// parse_pattern("room:lobby") // -> Exact("room:lobby")
/// parse_pattern("document:*:ops") // -> SegmentWildcard(["document", "*", "ops"])
/// parse_pattern("document:*:*") // -> SegmentWildcard(["document", "*", "*"])
/// parse_pattern("document:tenant-a:*") // -> Wildcard("document:tenant-a:")
/// ```
pub fn parse_pattern(pattern: String) -> TopicPattern {
  use <- bool.guard(
    when: should_parse_segment_wildcard(pattern),
    return: SegmentWildcard(segments(pattern)),
  )
  use <- bool.guard(
    when: !string.ends_with(pattern, "*"),
    return: Exact(pattern),
  )
  Wildcard(string.drop_end(pattern, 1))
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
/// matches(parse_pattern("document:*:ops"), "document:tenant-a:ops") // -> True
/// matches(parse_pattern("document:*:ops"), "document:tenant-a:view") // -> False
/// ```
pub fn matches(pattern: TopicPattern, topic: String) -> Bool {
  case pattern {
    Exact(p) -> p == topic
    Wildcard(prefix) -> string.starts_with(topic, prefix)
    SegmentWildcard(pattern_parts) ->
      segment_parts_match(pattern_parts, segments(topic))
  }
}

fn should_parse_segment_wildcard(pattern: String) -> Bool {
  let parts = segments(pattern)

  case has_full_wildcard_segment(parts) {
    False -> False
    True -> !string.ends_with(pattern, "*") || wildcard_segment_count(parts) > 1
  }
}

fn has_full_wildcard_segment(parts: List(String)) -> Bool {
  list.contains(parts, "*")
}

fn wildcard_segment_count(parts: List(String)) -> Int {
  parts
  |> list.filter(fn(part) { part == "*" })
  |> list.length
}

fn segment_parts_match(
  pattern_parts: List(String),
  topic_parts: List(String),
) -> Bool {
  list.length(pattern_parts) == list.length(topic_parts)
  && list.zip(pattern_parts, topic_parts)
  |> list.all(fn(pair) {
    case pair {
      #("*", _) -> True
      #(pattern_part, topic_part) -> pattern_part == topic_part
    }
  })
}

/// Errors from extracting wildcard values from a topic pattern.
pub type ExtractError {
  /// The pattern has no wildcard to extract.
  NoWildcard
  /// The topic does not match the pattern.
  TopicMismatch
  /// `extract_id` expected exactly one wildcard value but found this many.
  ExpectedOneWildcard(Int)
  /// `namespace` was called with an empty topic.
  EmptyNamespace
}

/// Extract the wildcard portion from a topic
///
/// ## Examples
///
/// ```gleam
/// extract_id(Wildcard("room:"), "room:lobby") // -> Ok("lobby")
/// extract_id(Wildcard("doc:"), "doc:abc:123") // -> Ok("abc:123")
/// extract_id(SegmentWildcard(["doc", "*", "ops"]), "doc:abc:ops") // -> Ok("abc")
/// extract_id(Exact("room:lobby"), "room:lobby") // -> Error(NoWildcard)
/// ```
pub fn extract_id(
  pattern: TopicPattern,
  topic: String,
) -> Result(String, ExtractError) {
  case pattern {
    Exact(_) -> Error(NoWildcard)
    Wildcard(prefix) -> {
      case string.starts_with(topic, prefix) {
        True -> Ok(string.drop_start(topic, string.length(prefix)))
        False -> Error(TopicMismatch)
      }
    }
    SegmentWildcard(_) ->
      case extract_wildcards(pattern, topic) {
        Ok([id]) -> Ok(id)
        Ok(values) -> Error(ExpectedOneWildcard(list.length(values)))
        Error(error) -> Error(error)
      }
  }
}

/// Extract values captured by wildcard segments.
///
/// For prefix wildcards, returns the suffix as a single value.
/// For segment wildcards, returns each topic segment matched by "*".
///
/// ## Examples
///
/// ```gleam
/// extract_wildcards(parse_pattern("document:*:*"), "document:tenant-a:doc-42")
/// // -> Ok(["tenant-a", "doc-42"])
/// ```
pub fn extract_wildcards(
  pattern: TopicPattern,
  topic: String,
) -> Result(List(String), ExtractError) {
  case pattern {
    Exact(p) ->
      case p == topic {
        True -> Ok([])
        False -> Error(TopicMismatch)
      }

    Wildcard(prefix) ->
      case string.starts_with(topic, prefix) {
        True -> Ok([string.drop_start(topic, string.length(prefix))])
        False -> Error(TopicMismatch)
      }

    SegmentWildcard(pattern_parts) -> {
      let topic_parts = segments(topic)

      case segment_parts_match(pattern_parts, topic_parts) {
        False -> Error(TopicMismatch)
        True -> Ok(collect_wildcard_values(pattern_parts, topic_parts))
      }
    }
  }
}

fn collect_wildcard_values(
  pattern_parts: List(String),
  topic_parts: List(String),
) -> List(String) {
  list.zip(pattern_parts, topic_parts)
  |> list.filter_map(fn(pair) {
    case pair {
      #("*", value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
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
/// namespace("") // -> Error(EmptyNamespace)
/// ```
pub fn namespace(topic: String) -> Result(String, ExtractError) {
  use <- bool.guard(when: string.is_empty(topic), return: Error(EmptyNamespace))
  topic
  |> segments
  |> list.first
  |> result.replace_error(EmptyNamespace)
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
/// - Not contain control characters (codepoints 0–31 or 127)
/// - Not start or end with ":"
pub fn validate(topic: String) -> Result(String, TopicError) {
  use <- bool.guard(when: string.is_empty(topic), return: Error(EmptyTopic))
  use <- bool.guard(
    when: string.starts_with(topic, ":") || string.ends_with(topic, ":"),
    return: Error(InvalidFormat("topic cannot start or end with ':'")),
  )
  use <- bool.guard(
    when: has_control_characters(topic),
    return: Error(InvalidFormat("topic contains control characters")),
  )
  Ok(topic)
}

/// Validate a topic pattern string
///
/// Patterns must:
/// - Not be empty
/// - Not contain control characters (codepoints 0–31 or 127)
///
/// The bare pattern `"*"` is valid: it parses to a catch-all wildcard that
/// matches every topic.
pub fn validate_pattern(pattern: String) -> Result(String, TopicError) {
  use <- bool.guard(when: string.is_empty(pattern), return: Error(EmptyTopic))
  use <- bool.guard(
    when: has_control_characters(pattern),
    return: Error(InvalidFormat("pattern contains control characters")),
  )
  Ok(pattern)
}

/// Validate an event name string
///
/// Event names must:
/// - Not be empty
/// - Not contain control characters (codepoints 0–31 or 127)
pub fn validate_event(event: String) -> Result(String, TopicError) {
  use <- bool.guard(
    when: string.is_empty(event),
    return: Error(InvalidFormat("event name is empty")),
  )
  use <- bool.guard(
    when: has_control_characters(event),
    return: Error(InvalidFormat("event contains control characters")),
  )
  Ok(event)
}

// nolint: unused_exports -- package-internal logging helper; hidden from public docs with @internal
/// Escape control characters in a string for safe use in log metadata.
///
/// Replaces codepoints in the range 0–31 and 127 with `?` so that
/// client-supplied strings cannot inject additional fields into structured
/// log output.
@internal
pub fn sanitize_for_log(value: String) -> String {
  string.to_utf_codepoints(value)
  |> list.map(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    case code < 32 || code == 127 {
      True -> "?"
      False -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.join("")
}

fn has_control_characters(value: String) -> Bool {
  string.to_utf_codepoints(value)
  |> list.any(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    code < 32 || code == 127
  })
}

/// Errors returned when validating a topic or topic pattern.
pub type TopicError {
  /// The topic or pattern was an empty string.
  EmptyTopic
  /// The topic, pattern, or event was malformed; the wrapped `String`
  /// describes the problem (e.g. leading/trailing `:` or control characters).
  InvalidFormat(String)
}
