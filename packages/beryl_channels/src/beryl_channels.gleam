//// Composable channels for beryl real-time sockets.
////
//// This package layers Phoenix-shaped channel modules on top of beryl's
//// public app-side dispatch API. An application registers a list of
//// [`channel.Handler`](/reference/api/beryl_channels-channel/#handler) values —
//// each a topic pattern plus a typed `join` callback — and the layer
//// routes every socket event to the channel that owns its topic. No
//// hand-written message union and no hand-written router are required,
//// and each channel keeps its own private state and server-side message
//// type.
////
//// ```gleam
//// import beryl
//// import beryl/wire
//// import beryl_channels
//// import beryl_channels/channel
//// import gleam/otp/static_supervisor
////
//// pub fn handlers() -> List(channel.Handler) {
////   [rooms.channel(), documents.channel()]
//// }
////
//// pub fn main() {
////   let assert Ok(#(sockets, spec)) =
////     beryl_channels.child_spec(
////       beryl.config(wire.phoenix_codec()),
////       handlers: handlers(),
////     )
////
////   let assert Ok(_root) =
////     static_supervisor.new(static_supervisor.OneForOne)
////     |> static_supervisor.add(spec)
////     |> static_supervisor.start()
//// }
//// ```
////
//// The returned `beryl.Sockets` is an ordinary core handle: pass it to a
//// transport (`beryl_mist`, `beryl_ewe`), to `beryl.broadcast`, and to
//// `beryl.stop`.
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
//// A join for a topic no handler matches is refused explicitly, with the
//// reason payload `{"reason": "unmatched topic"}`, rather than left
//// unanswered.

import beryl
import beryl/socket
import beryl/topic
import beryl_channels/channel
import beryl_channels/internal/router
import gleam/list
import gleam/otp/static_supervisor
import gleam/otp/supervision
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
  /// `pattern` is the offending pattern and `reason` is the
  /// [`beryl/topic`](https://beryl.tylerbutler.com/reference/api/beryl-topic/)
  /// error
  /// nested rather than flattened to a string, so it stays matchable.
  InvalidPattern(pattern: String, reason: topic.TopicError)
  /// Two handlers were registered with the same pattern string. The
  /// second one could never receive a join, because routing takes the
  /// first match.
  DuplicatePattern(pattern: String)
}

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
/// [`child_spec`](#child_spec) runs exactly this validation before building
/// anything, so a handler table that passes here is accepted there too.
pub fn validate_handlers(
  handlers: List(channel.Handler),
) -> Result(Nil, HandlerError) {
  let patterns = list.map(handlers, channel.pattern)
  use _ <- result.try(list.try_each(patterns, validate_pattern))
  check_duplicates(patterns, set.new())
}

/// Build a channel system's supervision child specification for embedding
/// in an application's supervision tree.
///
/// Like `beryl.child_spec`, this reports only what can be detected before
/// the tree is started: the handler table is validated first, then the
/// `beryl.Config`, whose error is returned nested in
/// [`ChildSpecInvalidConfig`](#childspecerror). The returned
/// `beryl.Sockets` is usable as soon as the owning tree is running.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(#(sockets, spec)) =
///   beryl_channels.child_spec(
///     beryl.config(wire.phoenix_codec()),
///     handlers: [rooms.channel()],
///   )
///
/// let assert Ok(_root) =
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(spec)
///   |> static_supervisor.start()
/// ```
pub fn child_spec(
  config: beryl.Config,
  handlers handlers: List(channel.Handler),
) -> Result(
  #(beryl.Sockets, supervision.ChildSpecification(static_supervisor.Supervisor)),
  ChildSpecError,
) {
  use table <- result.try(
    compile(handlers) |> result.map_error(ChildSpecInvalidHandlers),
  )

  beryl.child_spec(config, init: initialise(table), update: router.update)
  |> result.map_error(ChildSpecInvalidConfig)
}

/// Validate a handler table and parse its patterns once, before anything
/// is started.
fn compile(
  handlers: List(channel.Handler),
) -> Result(List(router.Registered), HandlerError) {
  use _ <- result.map(validate_handlers(handlers))
  router.table(handlers)
}

/// The core `init` for a compiled handler table: one router per socket.
fn initialise(
  table: List(router.Registered),
) -> fn(socket.ConnectInfo(router.Envelope)) ->
  #(router.Router, List(socket.Effect)) {
  fn(info) { router.init(table, info) }
}

fn validate_pattern(pattern: String) -> Result(String, HandlerError) {
  topic.validate_pattern(pattern)
  |> result.map_error(fn(error) {
    InvalidPattern(pattern: pattern, reason: error)
  })
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
