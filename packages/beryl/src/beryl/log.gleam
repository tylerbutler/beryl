//// Internal logging shim over `palabres`.
////
//// Not part of the public API. Provides a thin, named-logger call surface
//// (`logger |> log.debug(message, metadata)`) on top of the palabres global
//// logger. A `Logger` is just a named tag whose name is attached to every
//// emitted log under the `logger` field; palabres itself is a singleton
//// configured once at startup (see `beryl/internal.configure`).

import gleam/list
import palabres

/// A named logger tag. The name is emitted as the `logger` field on every log.
pub opaque type Logger {
  Logger(name: String)
}

/// Create a named logger.
pub fn new(name: String) -> Logger {
  Logger(name)
}

type Metadata =
  List(#(String, String))

fn emit(builder: palabres.Log, logger: Logger, metadata: Metadata) -> Nil {
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
  emit(palabres.debug(message), logger, metadata)
}

/// Emit an info-level log.
pub fn info(logger: Logger, message: String, metadata: Metadata) -> Nil {
  emit(palabres.info(message), logger, metadata)
}

/// Emit a warning-level log.
pub fn warn(logger: Logger, message: String, metadata: Metadata) -> Nil {
  emit(palabres.warning(message), logger, metadata)
}

/// Emit an error-level log.
pub fn error(logger: Logger, message: String, metadata: Metadata) -> Nil {
  emit(palabres.error(message), logger, metadata)
}
