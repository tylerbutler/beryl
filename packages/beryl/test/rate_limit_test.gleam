//// Tests for the pure token-bucket rate limiter.

import beryl/rate_limit
import gleam/erlang/process
import gleam/list
import gleeunit/should

fn take_n(
  bucket: rate_limit.Bucket,
  count: Int,
) -> #(rate_limit.Bucket, List(Result(Nil, Nil))) {
  case count <= 0 {
    True -> #(bucket, [])
    False -> {
      let #(bucket, taken) = rate_limit.take(bucket)
      let #(bucket, rest) = take_n(bucket, count - 1)
      #(bucket, [taken, ..rest])
    }
  }
}

pub fn burst_allows_up_to_capacity_test() {
  let bucket = rate_limit.new_bucket(rate_limit.config(per_second: 1, burst: 3))

  let #(bucket, results) = take_n(bucket, 3)
  results |> list.all(fn(taken) { taken == Ok(Nil) }) |> should.be_true

  // The bucket is empty now; the next take is limited.
  let #(_bucket, taken) = rate_limit.take(bucket)
  taken |> should.equal(Error(Nil))
}

pub fn burst_defaults_to_per_second_when_zero_test() {
  let bucket = rate_limit.new_bucket(rate_limit.config(per_second: 5, burst: 0))

  let #(bucket, results) = take_n(bucket, 5)
  results |> list.all(fn(taken) { taken == Ok(Nil) }) |> should.be_true

  let #(_bucket, taken) = rate_limit.take(bucket)
  taken |> should.equal(Error(Nil))
}

pub fn tokens_refill_over_time_test() {
  // 100 tokens/second = one token every 10ms.
  let bucket =
    rate_limit.new_bucket(rate_limit.config(per_second: 100, burst: 1))

  let #(bucket, taken) = rate_limit.take(bucket)
  taken |> should.equal(Ok(Nil))
  let #(bucket, taken) = rate_limit.take(bucket)
  taken |> should.equal(Error(Nil))

  // After enough time for at least one token to refill, a take succeeds.
  process.sleep(30)
  let #(_bucket, taken) = rate_limit.take(bucket)
  taken |> should.equal(Ok(Nil))
}

pub fn refill_never_exceeds_burst_capacity_test() {
  let bucket =
    rate_limit.new_bucket(rate_limit.config(per_second: 1000, burst: 2))

  // Wait long enough to refill far more than the burst if uncapped.
  process.sleep(50)

  let #(bucket, results) = take_n(bucket, 2)
  results |> list.all(fn(taken) { taken == Ok(Nil) }) |> should.be_true

  let #(_bucket, taken) = rate_limit.take(bucket)
  taken |> should.equal(Error(Nil))
}

pub fn independent_buckets_do_not_share_tokens_test() {
  let config = rate_limit.config(per_second: 1, burst: 1)
  let one = rate_limit.new_bucket(config)
  let two = rate_limit.new_bucket(config)

  let #(_one, taken_one) = rate_limit.take(one)
  taken_one |> should.equal(Ok(Nil))

  // Draining bucket one leaves bucket two untouched.
  let #(_two, taken_two) = rate_limit.take(two)
  taken_two |> should.equal(Ok(Nil))
}
