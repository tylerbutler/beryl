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

/// Configure the global palabres logger from a Beryl logging configuration.
///
/// Palabres is a singleton configured once at startup; the level set here is
/// global across every Beryl logger. Called when a coordinator starts.
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
    Err -> level.Error
  }
}

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
