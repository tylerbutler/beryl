//// Rate limiting for channels using a token bucket algorithm.
////
//// Provides per-key rate limiting backed by OTP actors. Each key (e.g. socket ID,
//// topic) gets its own token bucket that refills at a configured rate.

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
  |> result.replace_error(Nil)
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
  RegistryStop
}

fn handle_registry_msg(
  state: RegistryState,
  msg: RegistryMsg,
) -> actor.Next(RegistryState, RegistryMsg) {
  case msg {
    RegistryStop -> actor.stop()

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
      case dict.get(state.buckets, key) {
        Ok(bucket) -> process.send(bucket, BucketShutdown)
        Error(Nil) -> Nil
      }
      actor.continue(
        RegistryState(..state, buckets: dict.delete(state.buckets, key)),
      )
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

fn count_by_prefix(
  buckets: Dict(String, Subject(BucketMsg)),
  prefix: String,
) -> Int {
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
      hit_bucket(bucket, reply)
      state
    }
    Error(Nil) ->
      case start_bucket(state.config) {
        Ok(bucket) -> {
          hit_bucket(bucket, reply)
          RegistryState(
            ..state,
            buckets: dict.insert(state.buckets, key, bucket),
          )
        }
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          state
        }
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
    Ok(bucket) -> {
      hit_bucket(bucket, reply)
      state
    }
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

fn hit_bucket(
  bucket: Subject(BucketMsg),
  reply: Subject(Result(Nil, Nil)),
) -> Nil {
  let result = process.call(bucket, 100, fn(r) { Hit(reply: r) })
  process.send(reply, result)
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
  list.each(buckets, fn(kv) { process.send(kv.1, BucketShutdown) })
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
  |> result.replace_error(Nil)
}

/// Check if a request for the given key is allowed.
/// Returns Ok(Nil) if allowed, Error(Nil) if rate limited.
pub fn check(limiter: RateLimiter, key: String) -> Result(Nil, Nil) {
  process.call(limiter.subject, 100, fn(reply) { Check(key, reply) })
}

/// Check if a request is allowed, rejecting new keys after a per-prefix cap.
pub fn check_capped(
  limiter: RateLimiter,
  key: String,
  prefix: String,
  max_keys: Int,
) -> Result(Nil, Nil) {
  process.call(limiter.subject, 100, fn(reply) {
    CheckCapped(key: key, prefix: prefix, max_keys: max_keys, reply: reply)
  })
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
  process.call(limiter.subject, 100, fn(reply) { Count(reply: reply) })
}

/// Return the number of active token buckets matching a key prefix.
pub fn bucket_count_by_prefix(limiter: RateLimiter, prefix: String) -> Int {
  process.call(limiter.subject, 100, fn(reply) {
    CountByPrefix(prefix: prefix, reply: reply)
  })
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
  process.send(limiter.subject, RegistryStop)
}
