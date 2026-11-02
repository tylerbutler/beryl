//// Internal logging shim over `palabres`.
////
//// Not part of the public API. Provides a thin, named-logger call surface
//// (`logger |> log.debug(message, metadata)`) with a local minimum level.
//// The host application owns OTP Logger configuration and applies its own
//// filters after beryl's local threshold.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/string
import palabres

@external(erlang, "beryl_ffi", "logging_debug_enabled")
fn host_debug_enabled() -> Bool

/// Logging verbosity for beryl diagnostics.
pub type Level {
  Debug
  Info
  Warn
  ErrorLevel
}

/// A named logger with a local threshold.
pub opaque type Logger {
  Logger(name: String, minimum: Level)
}

/// Create a named logger that defers filtering to the host application.
pub fn new(name: String) -> Logger {
  Logger(name, Debug)
}

/// Set this logger's minimum level without changing OTP Logger.
pub fn with_level(logger: Logger, minimum: Level) -> Logger {
  Logger(..logger, minimum:)
}

type Metadata =
  List(#(String, String))

fn rank(level: Level) -> Int {
  case level {
    Debug -> 0
    Info -> 1
    Warn -> 2
    ErrorLevel -> 3
  }
}

fn emit(
  logger: Logger,
  level: Level,
  message: String,
  metadata: Metadata,
) -> Nil {
  use <- bool.guard(when: rank(level) < rank(logger.minimum), return: Nil)
  let builder = case level {
    Debug -> palabres.debug(message)
    Info -> palabres.info(message)
    Warn -> palabres.warning(message)
    ErrorLevel -> palabres.error(message)
  }
  builder
  |> palabres.string("logger", logger.name)
  |> apply_metadata(metadata)
  |> palabres.log
}

fn apply_metadata(builder: palabres.Log, metadata: Metadata) -> palabres.Log {
  use builder, #(key, value) <- list.fold(metadata, builder)
  let value = case key {
    "frame_preview" | "crash" -> value
    _ -> field(value)
  }
  palabres.string(builder, key, value)
}

/// Emit a debug-level log.
pub fn debug(logger: Logger, message: String, metadata: Metadata) -> Nil {
  debug_lazy(logger, message, fn() { metadata })
}

/// Construct debug metadata only when local and host levels permit debug.
///
/// Host primary and handler filters still apply at emission.
pub fn debug_lazy(
  logger: Logger,
  message: String,
  metadata: fn() -> Metadata,
) -> Nil {
  use <- bool.guard(when: logger.minimum != Debug, return: Nil)
  use <- bool.guard(when: !host_debug_enabled(), return: Nil)
  emit(logger, Debug, message, metadata())
}

/// Log an expected client rejection at debug with bounded string fields.
pub fn rejection(
  logger: Logger,
  message: String,
  metadata: fn() -> Metadata,
) -> Nil {
  debug_lazy(logger, message, metadata)
}

/// Sanitize a diagnostic field and bound it to 256 UTF-8 bytes.
///
/// C0, DEL, and C1 controls become `?`. Truncated text ends in `...`, included
/// in the byte limit. Scanning stops at the limit, even inside a grapheme.
pub fn field(text: String) -> String {
  let limit = case string.byte_size(text) > 256 {
    True -> 253
    False -> 256
  }
  field_prefix(bit_array.from_string(text), limit, [])
}

fn field_prefix(
  remaining: BitArray,
  available: Int,
  parts: List(String),
) -> String {
  case remaining {
    <<>> -> parts |> list.reverse |> string.concat
    <<codepoint:utf8_codepoint, rest:bits>> -> {
      let value = string.utf_codepoint_to_int(codepoint)
      let character = case value < 32 || value >= 127 && value <= 159 {
        True -> "?"
        False -> string.from_utf_codepoints([codepoint])
      }
      let bytes = string.byte_size(character)
      case bytes <= available {
        True -> field_prefix(rest, available - bytes, [character, ..parts])
        False -> ["...", ..parts] |> list.reverse |> string.concat
      }
    }
    _ -> parts |> list.reverse |> string.concat
  }
}

/// Emit an info-level log.
pub fn info(logger: Logger, message: String, metadata: Metadata) -> Nil {
  emit(logger, Info, message, metadata)
}

/// Emit a warning-level log.
pub fn warn(logger: Logger, message: String, metadata: Metadata) -> Nil {
  emit(logger, Warn, message, metadata)
}

/// Emit an error-level log.
pub fn error(logger: Logger, message: String, metadata: Metadata) -> Nil {
  emit(logger, ErrorLevel, message, metadata)
}
