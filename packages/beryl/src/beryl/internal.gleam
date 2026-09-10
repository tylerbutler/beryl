//// Internal utilities shared across beryl modules.
//// Not part of the public API.

import beryl/log.{type Logger}
import gleam/int
import gleam/string
import palabres
import palabres/level
import palabres/options

/// Logging verbosity for beryl's internal helpers.
pub type LogLevel {
  Debug
  Info
  Warn
  ErrorLevel
}

/// Logging configuration shared by internal beryl modules.
pub type LoggingConfig {
  LoggingConfig(
    level: LogLevel,
    include_payloads: Bool,
    payload_preview_bytes: Int,
  )
}

/// Configure the global palabres logger from a beryl logging configuration.
///
/// Palabres is a singleton configured once at startup; the level set here is
/// global across every beryl logger. Called when a runtime starts.
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
/// Capture exceptions within an explicitly selected operation.
///
/// Convert synchronous `error`, `exit`, and `throw` exceptions from the
/// callback into `Error(description)`. Use typed results and effects for
/// expected failures rather than raising exceptions.
///
/// Runtime and channel call sites use the error path to reject a join or close
/// the affected topic or socket, and complete protocol cleanup. Presence uses
/// it to retain its previous actor state if remote sync processing fails.
/// Callers must handle the error; this function does not undo side effects,
/// including ETS writes, that completed before the exception.
///
/// Faults outside the supplied callback still terminate the actor and follow
/// its supervision policy.
///
/// The FFI limits diagnostic depth and length to keep each crash description
/// bounded.
@external(erlang, "beryl_ffi", "rescue")
pub fn rescue(callback: fn() -> value) -> Result(value, String)

/// Return a named logger.
pub fn logger(name: String) -> Logger {
  log.new(name)
}

/// Build a named logger using the supplied beryl logging configuration.
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
