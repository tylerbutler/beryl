//// Pure token-bucket rate limiting.
////
//// A `Bucket` is plain data refilled against the monotonic clock — there is
//// no registry actor and no messaging. Callers own bucket storage (the
//// runtime keeps per-socket and per-channel buckets in its own state;
//// transports keep one per connection), so a check costs a dict update
//// instead of a blocking cross-process call, cleanup is deleting the entry,
//// and nothing leaks when a supervisor restarts the owner.

import gleam/int

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

// ── Token bucket ────────────────────────────────────────────────────────────

/// A token bucket. Create with `new_bucket`, consume with `take`.
pub opaque type Bucket {
  Bucket(
    tokens_ns: Int,
    max_tokens_ns: Int,
    ns_per_token: Int,
    last_refill_ns: Int,
  )
}

const one_second_ns = 1_000_000_000

/// Create a full bucket for the given config.
pub fn new_bucket(cfg: RateLimitConfig) -> Bucket {
  let ns_per_token = one_second_ns / int.max(cfg.per_second, 1)
  Bucket(
    tokens_ns: cfg.burst * ns_per_token,
    max_tokens_ns: cfg.burst * ns_per_token,
    ns_per_token: ns_per_token,
    last_refill_ns: monotonic_time_ns(),
  )
}

/// Refill the bucket for elapsed time and try to take one token.
///
/// Returns the updated bucket and `Ok(Nil)` when a token was available, or
/// `Error(Nil)` when the caller is rate limited.
pub fn take(bucket: Bucket) -> #(Bucket, Result(Nil, Nil)) {
  let bucket = refill(bucket)
  case bucket.tokens_ns >= bucket.ns_per_token {
    True -> #(
      Bucket(..bucket, tokens_ns: bucket.tokens_ns - bucket.ns_per_token),
      Ok(Nil),
    )
    False -> #(bucket, Error(Nil))
  }
}

fn refill(bucket: Bucket) -> Bucket {
  let now = monotonic_time_ns()
  let elapsed = now - bucket.last_refill_ns
  case elapsed > 0 {
    False -> bucket
    True -> {
      let new_tokens = int.min(bucket.tokens_ns + elapsed, bucket.max_tokens_ns)
      Bucket(..bucket, tokens_ns: new_tokens, last_refill_ns: now)
    }
  }
}
