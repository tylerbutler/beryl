//// Shared beryl-owned error helpers.

import gleam/erlang/process
import gleam/otp/actor

/// A stable description of an internal beryl actor startup failure.
///
/// This type hides OTP's `actor.StartError` so public APIs do not expose
/// dependency-specific error constructors.
pub opaque type StartFailure {
  StartFailure(reason: StartFailureReason)
}

type StartFailureReason {
  StartTimedOut
  StartFailed(String)
  StartExited(process.ExitReason)
}

/// Return a human-readable description of a startup failure.
///
/// Abnormal exits retain their underlying reason internally. Their description
/// includes a depth- and length-limited rendering so large exit terms cannot
/// produce unbounded diagnostic output.
pub fn describe_start_failure(failure: StartFailure) -> String {
  case failure.reason {
    StartTimedOut -> "actor init timed out"
    StartFailed(reason) -> "actor init failed: " <> reason
    StartExited(reason) ->
      "actor init exited: " <> exit_reason_to_string(reason)
  }
}

/// Convert a `gleam/otp/actor.StartError` to beryl's `StartFailure`.
pub fn from_actor_start_error(error: actor.StartError) -> StartFailure {
  case error {
    actor.InitTimeout -> StartFailure(StartTimedOut)
    actor.InitFailed(reason) -> StartFailure(StartFailed(reason))
    actor.InitExited(reason) -> StartFailure(StartExited(reason))
  }
}

fn exit_reason_to_string(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(_) -> "abnormal: " <> describe_abnormal_exit(reason)
  }
}

@external(erlang, "beryl_error_ffi", "describe_abnormal_exit")
fn describe_abnormal_exit(reason: process.ExitReason) -> String
