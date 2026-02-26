//// Internal utilities shared across beryl modules.
//// Not part of the public API.

import birch
import birch/logger.{type Logger}

/// Return a memoized named logger, creating it on first call via persistent_term.
/// The hot path is a single persistent_term lookup with no allocations.
pub fn logger(name: String) -> Logger {
  case get_cached_logger(name) {
    Ok(l) -> l
    Error(Nil) -> {
      let l = birch.new(name)
      set_cached_logger(name, l)
      l
    }
  }
}

@external(erlang, "beryl_ffi", "get_cached_logger")
fn get_cached_logger(name: String) -> Result(Logger, Nil)

@external(erlang, "beryl_ffi", "set_cached_logger")
fn set_cached_logger(name: String, logger: Logger) -> Nil
