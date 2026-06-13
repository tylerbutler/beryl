//// Internal utilities shared across beryl modules.
//// Not part of the public API.

import birch
import birch/level
import birch/logger.{type Logger}
import gleam/int
import gleam/string

/// Logging verbosity for Beryl's internal helpers.
pub type LogLevel {
  Trace
  Debug
  Info
  Warn
  Err
}

/// Logging configuration shared by internal Beryl modules.
pub type LoggingConfig {
  LoggingConfig(
    level: LogLevel,
    include_payloads: Bool,
    payload_preview_bytes: Int,
  )
}

/// Return a memoized named logger, creating it on first call via persistent_term.
/// The hot path is a single persistent_term lookup with no allocations.
pub fn logger(name: String) -> Logger {
  case get_cached_logger(name) {
    Ok(cached_logger) -> cached_logger
    Error(Nil) -> {
      let cached_logger = birch.new(name)
      set_cached_logger(name, cached_logger)
      cached_logger
    }
  }
}

/// Build a named logger using the supplied Beryl logging configuration.
pub fn logger_with_config(name: String, config: LoggingConfig) -> Logger {
  birch.new(name)
  |> birch.with_level(to_birch_level(config.level))
}

fn to_birch_level(log_level: LogLevel) -> level.Level {
  case log_level {
    Trace -> level.Trace
    Debug -> level.Debug
    Info -> level.Info
    Warn -> level.Warn
    Err -> level.Err
  }
}

/// Safely truncate a text value for log metadata.
fn safe_preview(text: String, max_length: Int) -> String {
  let safe_length = int.max(max_length, 0)
  string.slice(text, 0, safe_length)
}

/// Return bounded preview metadata only when payload logging is enabled.
pub fn preview_metadata(
  key: String,
  text: String,
  config: LoggingConfig,
) -> List(#(String, String)) {
  case config.include_payloads {
    True -> [#(key, safe_preview(text, config.payload_preview_bytes))]
    False -> []
  }
}

@external(erlang, "beryl_ffi", "get_cached_logger")
fn get_cached_logger(name: String) -> Result(Logger, Nil)

@external(erlang, "beryl_ffi", "set_cached_logger")
fn set_cached_logger(name: String, logger: Logger) -> Nil
