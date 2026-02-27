//// Rate limiting for channels using a token bucket algorithm.
////
//// Provides per-key rate limiting backed by OTP actors. Each key (e.g. socket ID,
//// topic) gets its own token bucket that refills at a configured rate.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

/// Erlang monotonic time in nanoseconds
@external(erlang, "beryl_ffi", "monotonic_time_ns")
fn monotonic_time_ns() -> Int

// ── Configuration ───────────────────────────────────────────────────────────

/// Rate limit configuration
pub type RateLimitConfig {
  RateLimitConfig(
    /// Tokens added per second (sustained rate)
    per_second: Int,
    /// Maximum tokens (burst capacity). Defaults to per_second if 0.
    burst: Int,
  )
}

/// Create a rate limit config. Burst defaults to per_second if set to 0.
pub fn config(per_second per_second: Int, burst burst: Int) -> RateLimitConfig {
  let effective_burst = case burst {
    0 -> per_second
    b -> b
  }
  RateLimitConfig(per_second: per_second, burst: effective_burst)
}

// ── Token Bucket Actor ─────────────────────────────────────────────────────

type BucketState {
  BucketState(
    tokens_ns: Int,
    max_tokens_ns: Int,
    ns_per_token: Int,
    last_refill_ns: Int,
  )
}

type BucketMsg {
  Hit(reply: Subject(Result(Nil, Nil)))
  BucketShutdown
}

const one_second_ns = 1_000_000_000

fn new_bucket_state(cfg: RateLimitConfig) -> BucketState {
  let ns_per_token = one_second_ns / int.max(cfg.per_second, 1)
  BucketState(
    tokens_ns: cfg.burst * ns_per_token,
    max_tokens_ns: cfg.burst * ns_per_token,
    ns_per_token: ns_per_token,
    last_refill_ns: monotonic_time_ns(),
  )
}

fn refill(state: BucketState) -> BucketState {
  let now = monotonic_time_ns()
  let elapsed = now - state.last_refill_ns
  case elapsed > 0 {
    False -> state
    True -> {
      let new_tokens = int.min(state.tokens_ns + elapsed, state.max_tokens_ns)
      BucketState(..state, tokens_ns: new_tokens, last_refill_ns: now)
    }
  }
}

fn handle_bucket_msg(
  state: BucketState,
  msg: BucketMsg,
) -> actor.Next(BucketState, BucketMsg) {
  case msg {
    BucketShutdown -> actor.stop()
    Hit(reply) -> {
      let state = refill(state)
      case state.tokens_ns >= state.ns_per_token {
        True -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            BucketState(
              ..state,
              tokens_ns: state.tokens_ns - state.ns_per_token,
            ),
          )
        }
        False -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
      }
    }
  }
}

fn start_bucket(cfg: RateLimitConfig) -> Result(Subject(BucketMsg), Nil) {
  actor.new(new_bucket_state(cfg))
  |> actor.on_message(handle_bucket_msg)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(_) { Nil })
}

// ── Registry (per-key rate limiters) ────────────────────────────────────────

/// Opaque rate limiter registry that manages per-key token buckets.
pub opaque type RateLimiter {
  RateLimiter(subject: Subject(RegistryMsg))
}

type RegistryState {
  RegistryState(
    config: RateLimitConfig,
    buckets: Dict(String, Subject(BucketMsg)),
  )
}

type RegistryMsg {
  Check(key: String, reply: Subject(Result(Nil, Nil)))
  RemoveByPrefix(prefix: String)
  RegistryStop
}

fn handle_registry_msg(
  state: RegistryState,
  msg: RegistryMsg,
) -> actor.Next(RegistryState, RegistryMsg) {
  case msg {
    RegistryStop -> actor.stop()

    Check(key, reply) -> {
      case dict.get(state.buckets, key) {
        Ok(bucket) -> {
          let result = process.call(bucket, 100, fn(r) { Hit(reply: r) })
          process.send(reply, result)
          actor.continue(state)
        }
        Error(_) -> {
          case start_bucket(state.config) {
            Ok(bucket) -> {
              let result = process.call(bucket, 100, fn(r) { Hit(reply: r) })
              process.send(reply, result)
              let new_buckets = dict.insert(state.buckets, key, bucket)
              actor.continue(RegistryState(..state, buckets: new_buckets))
            }
            Error(_) -> {
              process.send(reply, Ok(Nil))
              actor.continue(state)
            }
          }
        }
      }
    }

    RemoveByPrefix(prefix) -> {
      let #(to_remove, to_keep) =
        dict.to_list(state.buckets)
        |> split_by_prefix(prefix, [], [])
      shut_down_buckets(to_remove)
      actor.continue(RegistryState(..state, buckets: dict.from_list(to_keep)))
    }
  }
}

fn split_by_prefix(
  entries: List(#(String, Subject(BucketMsg))),
  prefix: String,
  matching: List(#(String, Subject(BucketMsg))),
  rest: List(#(String, Subject(BucketMsg))),
) -> #(List(#(String, Subject(BucketMsg))), List(#(String, Subject(BucketMsg)))) {
  case entries {
    [] -> #(matching, rest)
    [#(key, bucket), ..tail] -> {
      case string_starts_with(key, prefix) {
        True ->
          split_by_prefix(tail, prefix, [#(key, bucket), ..matching], rest)
        False ->
          split_by_prefix(tail, prefix, matching, [#(key, bucket), ..rest])
      }
    }
  }
}

fn shut_down_buckets(buckets: List(#(String, Subject(BucketMsg)))) -> Nil {
  case buckets {
    [] -> Nil
    [#(_, bucket), ..rest] -> {
      process.send(bucket, BucketShutdown)
      shut_down_buckets(rest)
    }
  }
}

@external(erlang, "beryl_ffi", "string_starts_with")
fn string_starts_with(string: String, prefix: String) -> Bool

// ── Public API ──────────────────────────────────────────────────────────────

/// Start a new rate limiter registry with the given config.
/// All keys managed by this registry share the same rate/burst settings.
pub fn start(cfg: RateLimitConfig) -> Result(RateLimiter, Nil) {
  let state = RegistryState(config: cfg, buckets: dict.new())
  actor.new(state)
  |> actor.on_message(handle_registry_msg)
  |> actor.start
  |> result.map(fn(started) { RateLimiter(subject: started.data) })
  |> result.map_error(fn(_) { Nil })
}

/// Check if a request for the given key is allowed.
/// Returns Ok(Nil) if allowed, Error(Nil) if rate limited.
pub fn check(limiter: RateLimiter, key: String) -> Result(Nil, Nil) {
  process.call(limiter.subject, 100, fn(reply) { Check(key, reply) })
}

/// Check an optional rate limiter. If None, always allows.
pub fn check_optional(
  limiter: Option(RateLimiter),
  key: String,
) -> Result(Nil, Nil) {
  case limiter {
    None -> Ok(Nil)
    Some(l) -> check(l, key)
  }
}

/// Remove all rate limit state for keys matching a prefix.
/// Call this when a socket disconnects to clean up its buckets.
pub fn remove_by_prefix(limiter: RateLimiter, prefix: String) -> Nil {
  process.send(limiter.subject, RemoveByPrefix(prefix))
}

/// Remove rate limit state for keys matching a prefix (optional limiter).
pub fn remove_by_prefix_optional(
  limiter: Option(RateLimiter),
  prefix: String,
) -> Nil {
  case limiter {
    None -> Nil
    Some(l) -> remove_by_prefix(l, prefix)
  }
}

/// Stop the rate limiter registry.
pub fn stop(limiter: RateLimiter) -> Nil {
  process.send(limiter.subject, RegistryStop)
}
