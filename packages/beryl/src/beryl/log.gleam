//// Internal logging shim over `palabres`.
////
//// Not part of the public API. Provides a thin, named-logger call surface
//// (`logger |> log.debug(message, metadata)`) with a local minimum level.
//// The host application owns OTP Logger configuration and applies its own
//// filters after beryl's local threshold.

import gleam/bool
import gleam/list
import palabres

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
  palabres.string(builder, key, value)
}

/// Emit a debug-level log.
pub fn debug(logger: Logger, message: String, metadata: Metadata) -> Nil {
  emit(logger, Debug, message, metadata)
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
