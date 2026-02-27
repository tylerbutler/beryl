import beryl/rate_limit
import gleam/erlang/process
import gleam/option
import gleeunit/should

// ── Token bucket basic behavior ─────────────────────────────────────────────

pub fn rate_limiter_allows_within_limit_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 100, burst: 10))

  // First 10 requests should be allowed (burst capacity)
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))

  rate_limit.stop(limiter)
}

pub fn rate_limiter_rejects_over_limit_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 100, burst: 3))

  // Exhaust the burst
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))

  // Should be rate limited now
  should.be_error(rate_limit.check(limiter, "key1"))

  rate_limit.stop(limiter)
}

pub fn rate_limiter_per_key_isolation_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 100, burst: 2))

  // Exhaust key1's bucket
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_error(rate_limit.check(limiter, "key1"))

  // key2 should still have full bucket
  should.be_ok(rate_limit.check(limiter, "key2"))
  should.be_ok(rate_limit.check(limiter, "key2"))

  rate_limit.stop(limiter)
}

pub fn rate_limiter_refills_over_time_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 100, burst: 2))

  // Exhaust the bucket
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_error(rate_limit.check(limiter, "key1"))

  // Wait for tokens to refill (at 100/sec, 1 token every 10ms)
  process.sleep(25)

  // Should have tokens again
  should.be_ok(rate_limit.check(limiter, "key1"))

  rate_limit.stop(limiter)
}

// ── Optional limiter ────────────────────────────────────────────────────────

pub fn check_optional_none_always_allows_test() {
  // None limiter should always allow
  should.be_ok(rate_limit.check_optional(option.None, "any_key"))
}

pub fn check_optional_some_applies_limit_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 100, burst: 1))

  should.be_ok(rate_limit.check_optional(option.Some(limiter), "key1"))
  should.be_error(rate_limit.check_optional(option.Some(limiter), "key1"))

  rate_limit.stop(limiter)
}

// ── Cleanup ─────────────────────────────────────────────────────────────────

pub fn remove_by_prefix_cleans_up_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 100, burst: 2))

  // Create some buckets
  should.be_ok(rate_limit.check(limiter, "ch:socket1:room:lobby"))
  should.be_ok(rate_limit.check(limiter, "ch:socket1:room:lobby"))
  should.be_error(rate_limit.check(limiter, "ch:socket1:room:lobby"))

  // Remove by prefix for socket1
  rate_limit.remove_by_prefix(limiter, "ch:socket1:")

  // After cleanup, a new bucket is created — should be allowed again
  should.be_ok(rate_limit.check(limiter, "ch:socket1:room:lobby"))

  rate_limit.stop(limiter)
}

pub fn remove_by_prefix_preserves_other_keys_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 100, burst: 2))

  // Create buckets for two sockets
  should.be_ok(rate_limit.check(limiter, "ch:socket1:topic"))
  should.be_ok(rate_limit.check(limiter, "ch:socket1:topic"))
  should.be_ok(rate_limit.check(limiter, "ch:socket2:topic"))
  should.be_ok(rate_limit.check(limiter, "ch:socket2:topic"))

  // Remove socket1 only
  rate_limit.remove_by_prefix(limiter, "ch:socket1:")

  // socket2's state should be preserved (still limited)
  should.be_error(rate_limit.check(limiter, "ch:socket2:topic"))

  rate_limit.stop(limiter)
}

// ── Burst defaults ──────────────────────────────────────────────────────────

pub fn burst_defaults_to_per_second_test() {
  let assert Ok(limiter) =
    rate_limit.start(rate_limit.config(per_second: 5, burst: 0))

  // With burst=0, it defaults to per_second (5)
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_ok(rate_limit.check(limiter, "key1"))
  should.be_error(rate_limit.check(limiter, "key1"))

  rate_limit.stop(limiter)
}

// ── Remove by prefix optional ───────────────────────────────────────────────

pub fn remove_by_prefix_optional_none_is_noop_test() {
  // Should not crash
  rate_limit.remove_by_prefix_optional(option.None, "anything")
}
