//// Composable channels for beryl real-time sockets.
////
//// This package layers Phoenix-shaped channel modules on top of beryl's
//// public app-side dispatch API. An application registers a list of
//// [`channel.Handler`](./beryl_channels/channel.html#Handler) values —
//// each a topic pattern plus a typed `join` callback — and the layer
//// routes every socket event to the channel that owns its topic. No
//// hand-written message union and no hand-written router are required,
//// and each channel keeps its own private state and server-side message
//// type.
////
//// ```gleam
//// import beryl_channels
//// import beryl_channels/channel
////
//// pub fn handlers() -> List(channel.Handler) {
////   [rooms.channel(), documents.channel()]
//// }
////
//// pub fn main() {
////   let assert Ok(Nil) = beryl_channels.validate_handlers(handlers())
//// }
//// ```
////
//// ## Routing rules
////
//// Handlers are consulted in list order and the first pattern that
//// matches a topic owns it, so more specific patterns belong earlier in
//// the list. Overlapping patterns are allowed on purpose — `"room:lobby"`
//// ahead of `"room:*"` is the normal way to special-case one topic. Two
//// handlers registered with the *same* pattern string are rejected
//// instead, because the second one could never be reached.
////
//// ## Status
////
//// The handler surface, the error surface, and the validation below are
//// complete. The supervised socket entry point that builds a child
//// specification from a handler table lands together with the dispatch
//// adapter; it is deliberately absent rather than present and inert.

import beryl
import beryl/topic
import beryl_channels/channel
import gleam/list
import gleam/result
import gleam/set

/// Why a handler table was rejected.
///
/// Validation is deterministic and two-phase: every pattern's syntax is
/// checked in registration order first, then duplicate pattern strings are
/// looked for in registration order. The first problem found in that order
/// is the one reported.
pub type HandlerError {
  /// A handler used a pattern string that is not a valid topic pattern.
  /// `pattern` is the offending pattern and `reason` describes the
  /// problem.
  InvalidPattern(pattern: String, reason: String)
  /// Two handlers were registered with the same pattern string. The
  /// second one could never receive a join, because routing takes the
  /// first match.
  DuplicatePattern(pattern: String)
}

// nolint: unused_exports -- consumed by `child_spec`, which lands with the dispatch adapter
/// Why building a channel-system child specification failed.
///
/// Like `beryl.child_spec`, this reports only the failures that can be
/// detected before the supervision tree is started.
pub type ChildSpecError {
  /// The handler table failed validation, exactly as
  /// [`validate_handlers`](#validate_handlers) reports it.
  ChildSpecInvalidHandlers(HandlerError)
  /// The `beryl.Config` failed the core's eager validation. The wrapped
  /// value is the core error exactly as `beryl.child_spec` returned it.
  ChildSpecInvalidConfig(beryl.ConfigError)
}

/// Validate a handler table without starting anything.
///
/// Checks, in registration order, that every pattern is a valid beryl
/// topic pattern, then — again in registration order — that no pattern
/// string is registered twice. Overlapping but non-identical patterns
/// (`"room:lobby"` and `"room:*"`) are valid: routing resolves them by
/// first match.
///
/// The socket entry points run exactly this validation before starting
/// anything, so a handler table that passes here is accepted there too.
pub fn validate_handlers(
  handlers: List(channel.Handler),
) -> Result(Nil, HandlerError) {
  let patterns = list.map(handlers, channel.pattern)
  use _ <- result.try(list.try_each(patterns, validate_pattern))
  check_duplicates(patterns, set.new())
}

fn validate_pattern(pattern: String) -> Result(String, HandlerError) {
  topic.validate_pattern(pattern)
  |> result.map_error(fn(error) {
    InvalidPattern(pattern: pattern, reason: reason(error))
  })
}

fn reason(error: topic.TopicError) -> String {
  case error {
    topic.EmptyTopic -> "pattern cannot be empty"
    topic.InvalidFormat(detail) -> detail
  }
}

fn check_duplicates(
  patterns: List(String),
  seen: set.Set(String),
) -> Result(Nil, HandlerError) {
  case patterns {
    [] -> Ok(Nil)
    [pattern, ..rest] ->
      case set.contains(seen, pattern) {
        True -> Error(DuplicatePattern(pattern))
        False -> check_duplicates(rest, set.insert(seen, pattern))
      }
  }
}
