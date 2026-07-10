//// Rate limiting for channels using a token bucket algorithm.
////
//// Provides per-key rate limiting backed by a single OTP registry actor. Each
//// key (e.g. socket ID, topic) stores token bucket state in the registry.

import gleam/bool
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
  RegistryState(
    config: RateLimitConfig,
    groups: Dict(String, Dict(String, BucketState)),
    bucket_count: Int,
  )
}

type RegistryMsg {
  Check(group: String, key: String, reply: Subject(Result(Nil, Nil)))
  CheckCapped(
    group: String,
    key: String,
    max_keys: Int,
    reply: Subject(Result(Nil, Nil)),
  )
  Count(reply: Subject(Int))
  CountGroup(group: String, reply: Subject(Int))
  RemoveKey(group: String, key: String)
  RemoveGroup(group: String)
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

    Check(group, key, reply) ->
      actor.continue(check_key(state, group, key, reply))

    CheckCapped(group, key, max_keys, reply) ->
      actor.continue(check_key_capped(state, group, key, max_keys, reply))

    Count(reply) -> {
      process.send(reply, state.bucket_count)
      actor.continue(state)
    }

    CountGroup(group, reply) -> {
      process.send(reply, group_size(state, group))
      actor.continue(state)
    }

    RemoveKey(group, key) -> actor.continue(remove_key(state, group, key))

    RemoveGroup(group) -> actor.continue(remove_group_state(state, group))
  }
}

fn group_size(state: RegistryState, group: String) -> Int {
  dict.get(state.groups, group)
  |> result.map(dict.size)
  |> result.unwrap(0)
}

fn check_key(
  state: RegistryState,
  group: String,
  key: String,
  reply: Subject(Result(Nil, Nil)),
) -> RegistryState {
  let buckets =
    dict.get(state.groups, group)
    |> result.unwrap(dict.new())

  case dict.get(buckets, key) {
    Ok(bucket) -> {
      let #(updated_bucket, check_result) = take_token(bucket)
      process.send(reply, check_result)
      RegistryState(
        ..state,
        groups: dict.insert(
          state.groups,
          group,
          dict.insert(buckets, key, updated_bucket),
        ),
      )
    }
    Error(Nil) -> {
      let #(new_bucket, check_result) =
        take_token(new_bucket_state(state.config))
      process.send(reply, check_result)
      RegistryState(
        ..state,
        groups: dict.insert(
          state.groups,
          group,
          dict.insert(buckets, key, new_bucket),
        ),
        bucket_count: state.bucket_count + 1,
      )
    }
  }
}

fn check_key_capped(
  state: RegistryState,
  group: String,
  key: String,
  max_keys: Int,
  reply: Subject(Result(Nil, Nil)),
) -> RegistryState {
  let buckets =
    dict.get(state.groups, group)
    |> result.unwrap(dict.new())

  case dict.get(buckets, key) {
    Ok(_) -> check_key(state, group, key, reply)
    Error(Nil) -> {
      case max_keys > 0 && dict.size(buckets) >= max_keys {
        True -> {
          process.send(reply, Error(Nil))
          state
        }
        False -> check_key(state, group, key, reply)
      }
    }
  }
}

fn remove_key(
  state: RegistryState,
  group: String,
  key: String,
) -> RegistryState {
  case dict.get(state.groups, group) {
    Error(Nil) -> state
    Ok(buckets) ->
      case dict.get(buckets, key) {
        Error(Nil) -> state
        Ok(_) -> {
          let remaining = dict.delete(buckets, key)
          let groups = case dict.is_empty(remaining) {
            True -> dict.delete(state.groups, group)
            False -> dict.insert(state.groups, group, remaining)
          }
          RegistryState(
            ..state,
            groups: groups,
            bucket_count: state.bucket_count - 1,
          )
        }
      }
  }
}

fn remove_group_state(state: RegistryState, group: String) -> RegistryState {
  case dict.get(state.groups, group) {
    Error(Nil) -> state
    Ok(buckets) ->
      RegistryState(
        ..state,
        groups: dict.delete(state.groups, group),
        bucket_count: state.bucket_count - dict.size(buckets),
      )
  }
}

// Send a registry request without letting timeouts or dead subjects exit the
// caller. If the limiter is unavailable, return the provided fallback so rate
// limiting fails open instead of taking down the coordinator.
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
  let state = RegistryState(config: cfg, groups: dict.new(), bucket_count: 0)
  actor.new(state)
  |> actor.on_message(handle_registry_msg)
  |> actor.start
  |> result.map(fn(started) { RateLimiter(subject: started.data) })
  |> result.replace_error(Nil)
}

/// Check if a request for the given group and key is allowed.
/// Returns Ok(Nil) if allowed, Error(Nil) if rate limited.
pub fn check(
  limiter: RateLimiter,
  group: String,
  key: String,
) -> Result(Nil, Nil) {
  request(
    limiter.subject,
    registry_call_timeout_ms,
    fn(reply) { Check(group, key, reply) },
    Ok(Nil),
  )
}

/// Check if a request is allowed, rejecting new keys after a per-group cap.
pub fn check_capped(
  limiter: RateLimiter,
  group: String,
  key: String,
  max_keys: Int,
) -> Result(Nil, Nil) {
  request(
    limiter.subject,
    registry_call_timeout_ms,
    fn(reply) {
      CheckCapped(group: group, key: key, max_keys: max_keys, reply: reply)
    },
    Ok(Nil),
  )
}

/// Check an optional rate limiter. If None, always allows.
pub fn check_optional(
  limiter: Option(RateLimiter),
  group: String,
  key: String,
) -> Result(Nil, Nil) {
  case limiter {
    None -> Ok(Nil)
    Some(l) -> check(l, group, key)
  }
}

/// Check an optional rate limiter with a per-group key cap.
pub fn check_capped_optional(
  limiter: Option(RateLimiter),
  group: String,
  key: String,
  max_keys: Int,
) -> Result(Nil, Nil) {
  case limiter {
    None -> Ok(Nil)
    Some(l) -> check_capped(l, group, key, max_keys)
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

/// Return the number of active token buckets in a group.
pub fn bucket_count_by_group(limiter: RateLimiter, group: String) -> Int {
  request(
    limiter.subject,
    registry_call_timeout_ms,
    fn(reply) { CountGroup(group: group, reply: reply) },
    0,
  )
}

/// Remove rate limit state for an exact group and key.
fn remove(limiter: RateLimiter, group: String, key: String) -> Nil {
  process.send(limiter.subject, RemoveKey(group, key))
}

/// Remove rate limit state for an exact group and key (optional limiter).
pub fn remove_optional(
  limiter: Option(RateLimiter),
  group: String,
  key: String,
) -> Nil {
  case limiter {
    None -> Nil
    Some(l) -> remove(l, group, key)
  }
}

/// Remove all rate limit state for a group.
/// Call this when a socket disconnects to clean up its buckets.
pub fn remove_group(limiter: RateLimiter, group: String) -> Nil {
  process.send(limiter.subject, RemoveGroup(group))
}

/// Remove all rate limit state for a group (optional limiter).
pub fn remove_group_optional(
  limiter: Option(RateLimiter),
  group: String,
) -> Nil {
  case limiter {
    None -> Nil
    Some(l) -> remove_group(l, group)
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

/// Stop the rate limiter if one is present; a no-op when `None`.
pub fn stop_optional(limiter: Option(RateLimiter)) -> Nil {
  case limiter {
    Some(limiter) -> stop(limiter)
    None -> Nil
  }
}
