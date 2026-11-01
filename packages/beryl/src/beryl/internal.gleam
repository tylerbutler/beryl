//// Internal utilities shared across beryl modules.
//// Not part of the public API.

import beryl/log.{type Logger}
import gleam/int
import gleam/string

/// Logging verbosity for beryl's internal helpers.
pub type LogLevel =
  log.Level

/// Logging configuration shared by internal beryl modules.
pub type LoggingConfig {
  LoggingConfig(
    level: LogLevel,
    include_payloads: Bool,
    payload_preview_bytes: Int,
  )
}

/// Create a logger with this system's local threshold.
pub fn configured_logger(name: String, config: LoggingConfig) -> Logger {
  log.new(name)
  |> log.with_level(config.level)
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
/// Descriptions retain the exception class and a depth-10 reason, plus at most
/// three call sites (module, function, arity, and available file/line). Stack
/// arguments and other stack metadata are not formatted. Reason values are
/// still included: do not put secrets in exception reasons.
///
/// The copied UTF-8 description is at most 512 Unicode code points (2048
/// bytes). Half the text budget is reserved for call sites. Each frame is
/// limited to 80 code points; long names and source locations can be truncated.
@external(erlang, "beryl_ffi", "rescue")
pub fn rescue(callback: fn() -> value) -> Result(value, String)

/// Return a named logger.
pub fn logger(name: String) -> Logger {
  log.new(name)
}

@external(erlang, "binary", "copy")
fn copy_preview(text: String) -> String

/// Safely truncate a text value for log metadata.
fn safe_preview(text: String, max_length: Int) -> String {
  let safe_length = int.max(max_length, 0)
  string.slice(text, 0, safe_length)
  // Copy the final slice so a raw OTP Logger report cannot retain the frame.
  // String concatenation and string.repeat do not guarantee a fresh copy.
  |> copy_preview
}

/// Return a grapheme-limited preview only when payload logging is enabled.
///
/// Keep the existing grapheme contract: no diagnostic byte cap or truncation
/// marker is applied. Call only inside an enabled debug diagnostic.
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
