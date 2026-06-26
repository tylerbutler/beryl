//// Rate limiting for channels using a token bucket algorithm.
////
//// Provides per-key rate limiting backed by a single OTP registry actor. Each
//// key (e.g. socket ID, topic) stores token bucket state in the registry.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
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

// ── Token bucket state ─────────────────────────────────────────────────────

type BucketState {
  BucketState(
    tokens_ns: Int,
    max_tokens_ns: Int,
    ns_per_token: Int,
    last_refill_ns: Int,
  )
}

const one_second_ns = 1_000_000_000

const registry_call_timeout_ms = 100

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

fn take_token(state: BucketState) -> #(BucketState, Result(Nil, Nil)) {
  let state = refill(state)
  case state.tokens_ns >= state.ns_per_token {
    True -> #(
      BucketState(..state, tokens_ns: state.tokens_ns - state.ns_per_token),
      Ok(Nil),
    )
    False -> #(state, Error(Nil))
  }
}

// ── Registry (per-key rate limiters) ────────────────────────────────────────

/// Opaque rate limiter registry that manages per-key token buckets.
pub opaque type RateLimiter {
  RateLimiter(subject: Subject(RegistryMsg))
}

type RegistryState {
  RegistryState(config: RateLimitConfig, buckets: Dict(String, BucketState))
}

type RegistryMsg {
  Check(key: String, reply: Subject(Result(Nil, Nil)))
  CheckCapped(
    key: String,
    prefix: String,
    max_keys: Int,
    reply: Subject(Result(Nil, Nil)),
  )
  Count(reply: Subject(Int))
  CountByPrefix(prefix: String, reply: Subject(Int))
  RemoveKey(key: String)
  RemoveByPrefix(prefix: String)
  RegistryStop(reply: Subject(Nil))
}

fn handle_registry_msg(
  state: RegistryState,
  msg: RegistryMsg,
) -> actor.Next(RegistryState, RegistryMsg) {
  case msg {
    RegistryStop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }

    Check(key, reply) -> actor.continue(check_key(state, key, reply))

    CheckCapped(key, prefix, max_keys, reply) ->
      actor.continue(check_key_capped(state, key, prefix, max_keys, reply))

    Count(reply) -> {
      process.send(reply, list.length(dict.to_list(state.buckets)))
      actor.continue(state)
    }

    CountByPrefix(prefix, reply) -> {
      process.send(reply, count_by_prefix(state.buckets, prefix))
      actor.continue(state)
    }

    RemoveKey(key) -> {
      actor.continue(
        RegistryState(..state, buckets: dict.delete(state.buckets, key)),
      )
    }

    RemoveByPrefix(prefix) -> {
      let to_keep =
        dict.to_list(state.buckets)
        |> list.filter(fn(entry) { !string_starts_with(entry.0, prefix) })
      actor.continue(RegistryState(..state, buckets: dict.from_list(to_keep)))
    }
  }
}

fn count_by_prefix(buckets: Dict(String, BucketState), prefix: String) -> Int {
  dict.to_list(buckets)
  |> list.filter(fn(entry) { string_starts_with(entry.0, prefix) })
  |> list.length
}

fn check_key(
  state: RegistryState,
  key: String,
  reply: Subject(Result(Nil, Nil)),
) -> RegistryState {
  case dict.get(state.buckets, key) {
    Ok(bucket) -> {
      let #(updated_bucket, check_result) = take_token(bucket)
      process.send(reply, check_result)
      RegistryState(
        ..state,
        buckets: dict.insert(state.buckets, key, updated_bucket),
      )
    }
    Error(Nil) -> {
      let #(new_bucket, check_result) =
        take_token(new_bucket_state(state.config))
      process.send(reply, check_result)
      RegistryState(
        ..state,
        buckets: dict.insert(state.buckets, key, new_bucket),
      )
    }
  }
}

fn check_key_capped(
  state: RegistryState,
  key: String,
  prefix: String,
  max_keys: Int,
  reply: Subject(Result(Nil, Nil)),
) -> RegistryState {
  case dict.get(state.buckets, key) {
    Ok(_) -> check_key(state, key, reply)
    Error(Nil) -> {
      case max_keys > 0 && count_by_prefix(state.buckets, prefix) >= max_keys {
        True -> {
          process.send(reply, Error(Nil))
          state
        }
        False -> check_key(state, key, reply)
      }
    }
  }
}

@external(erlang, "beryl_ffi", "string_starts_with")
fn string_starts_with(string: String, prefix: String) -> Bool

fn request(
  subject: Subject(message),
  timeout_ms: Int,
  build_message: fn(Subject(response)) -> message,
  fallback: response,
) -> response {
  case process.subject_owner(subject) {
    Error(Nil) -> fallback
    Ok(_) -> {
      let reply_subject = process.new_subject()
      process.send(subject, build_message(reply_subject))
      case process.receive(reply_subject, timeout_ms) {
        Ok(value) -> value
        Error(Nil) -> fallback
      }
    }
  }
}

// ── Public API ──────────────────────────────────────────────────────────────

/// Start a new rate limiter registry with the given config.
/// All keys managed by this registry share the same rate/burst settings.
pub fn start(cfg: RateLimitConfig) -> Result(RateLimiter, Nil) {
  let state = RegistryState(config: cfg, buckets: dict.new())
  actor.new(state)
  |> actor.on_message(handle_registry_msg)
  |> actor.start
  |> result.map(fn(started) { RateLimiter(subject: started.data) })
  |> result.replace_error(Nil)
}

/// Check if a request for the given key is allowed.
/// Returns Ok(Nil) if allowed, Error(Nil) if rate limited.
pub fn check(limiter: RateLimiter, key: String) -> Result(Nil, Nil) {
  request(
    limiter.subject,
    registry_call_timeout_ms,
    fn(reply) { Check(key, reply) },
    Ok(Nil),
  )
}

/// Check if a request is allowed, rejecting new keys after a per-prefix cap.
pub fn check_capped(
  limiter: RateLimiter,
  key: String,
  prefix: String,
  max_keys: Int,
) -> Result(Nil, Nil) {
  request(
    limiter.subject,
    registry_call_timeout_ms,
    fn(reply) {
      CheckCapped(key: key, prefix: prefix, max_keys: max_keys, reply: reply)
    },
    Ok(Nil),
  )
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

/// Check an optional rate limiter with a per-prefix key cap.
pub fn check_capped_optional(
  limiter: Option(RateLimiter),
  key: String,
  prefix: String,
  max_keys: Int,
) -> Result(Nil, Nil) {
  case limiter {
    None -> Ok(Nil)
    Some(l) -> check_capped(l, key, prefix, max_keys)
  }
}

/// Return the number of active token buckets in the registry.
pub fn bucket_count(limiter: RateLimiter) -> Int {
  request(
    limiter.subject,
    registry_call_timeout_ms,
    fn(reply) { Count(reply: reply) },
    0,
  )
}

/// Return the number of active token buckets matching a key prefix.
pub fn bucket_count_by_prefix(limiter: RateLimiter, prefix: String) -> Int {
  request(
    limiter.subject,
    registry_call_timeout_ms,
    fn(reply) { CountByPrefix(prefix: prefix, reply: reply) },
    0,
  )
}

/// Remove rate limit state for an exact key.
pub fn remove(limiter: RateLimiter, key: String) -> Nil {
  process.send(limiter.subject, RemoveKey(key))
}

/// Remove rate limit state for an exact key (optional limiter).
pub fn remove_optional(limiter: Option(RateLimiter), key: String) -> Nil {
  case limiter {
    None -> Nil
    Some(l) -> remove(l, key)
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

/// Start an optional rate limiter. Returns None if rate is 0 (unlimited).
pub fn start_optional(rate: Int, burst: Int) -> Option(RateLimiter) {
  use <- bool.guard(when: rate <= 0, return: None)
  case start(config(per_second: rate, burst: burst)) {
    Ok(limiter) -> Some(limiter)
    Error(Nil) -> None
  }
}

/// Stop the rate limiter registry.
pub fn stop(limiter: RateLimiter) -> Nil {
  request(
    limiter.subject,
    registry_call_timeout_ms,
    fn(reply) { RegistryStop(reply) },
    Nil,
  )
}
