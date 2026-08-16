//// Internal utilities shared across beryl modules.
//// Not part of the public API.

import beryl/log.{type Logger}
import gleam/int
import gleam/string
import palabres
import palabres/level
import palabres/options

/// Logging verbosity for Beryl's internal helpers.
pub type LogLevel {
  Debug
  Info
  Warn
  ErrorLevel
}

/// Logging configuration shared by internal Beryl modules.
pub type LoggingConfig {
  LoggingConfig(
    level: LogLevel,
    include_payloads: Bool,
    payload_preview_bytes: Int,
  )
}

/// Configure the global palabres logger from a Beryl logging configuration.
///
/// Palabres is a singleton configured once at startup; the level set here is
/// global across every Beryl logger. Called when a runtime starts.
pub fn configure(config: LoggingConfig) -> Nil {
  options.defaults()
  |> options.level(to_palabres_level(config.level))
  |> palabres.configure
}

fn to_palabres_level(log_level: LogLevel) -> level.Level {
  case log_level {
    Debug -> level.Debug
    Info -> level.Info
    Warn -> level.Warning
    ErrorLevel -> level.Error
  }
}

pub fn result_error(error: e) -> Result(a, e) {
  Error(error)
}

// nolint: stringly_typed_error -- the error is the formatted BEAM crash description; callers wrap or log it at use sites
/// Run a callback, converting any BEAM crash (error/exit/throw) into an
/// `Error(description)` so a faulty callback cannot take down the shared actor
/// that invoked it.
///
/// The description is depth-limited and truncated by the FFI so a
/// client-triggered crash cannot bloat log metadata.
@external(erlang, "beryl_ffi", "rescue")
pub fn rescue(callback: fn() -> value) -> Result(value, String)

/// Return a named logger.
pub fn logger(name: String) -> Logger {
  log.new(name)
}

/// Build a named logger using the supplied Beryl logging configuration.
///
/// The level is applied globally via `configure`; the returned logger only
/// carries its name.
pub fn logger_with_config(name: String, _config: LoggingConfig) -> Logger {
  log.new(name)
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
