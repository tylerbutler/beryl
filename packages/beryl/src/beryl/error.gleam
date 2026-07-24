//// Shared Beryl-owned error helpers.

import gleam/erlang/process
import gleam/otp/actor
import gleam/string

/// A stable description of an internal Beryl actor startup failure.
///
/// This type hides OTP's `actor.StartError` so public APIs do not expose
/// dependency-specific error constructors.
pub opaque type StartFailure {
  StartFailure(reason: StartFailureReason)
}

type StartFailureReason {
  StartTimedOut
  StartFailed(String)
  StartExited(String)
}

/// Convert a startup failure to a human-readable diagnostic string.
pub fn describe_start_failure(failure: StartFailure) -> String {
  case failure.reason {
    StartTimedOut -> "actor init timed out"
    StartFailed(reason) -> "actor init failed: " <> reason
    StartExited(reason) -> "actor init exited: " <> reason
  }
}

/// Convert a `gleam/otp/actor.StartError` into beryl's `StartFailure`.
pub fn from_actor_start_error(error: actor.StartError) -> StartFailure {
  case error {
    actor.InitTimeout -> StartFailure(StartTimedOut)
    actor.InitFailed(reason) -> StartFailure(StartFailed(reason))
    actor.InitExited(reason) -> StartFailure(StartExited(exit_reason(reason)))
  }
}

fn exit_reason(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    // nolint: string_inspect -- abnormal exit reasons are arbitrary BEAM terms with no concrete type to serialize
    process.Abnormal(detail) -> "abnormal: " <> string.inspect(detail)
  }
}
