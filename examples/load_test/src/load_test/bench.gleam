//// Benchmark knobs read from the environment.

import envoy
import gleam/int
import gleam/result

/// `BENCH_CALLBACK_COST_US`: microseconds of CPU each message callback
/// burns before answering. Zero (the default) is the plain target.
pub fn callback_cost_us() -> Int {
  envoy.get("BENCH_CALLBACK_COST_US")
  |> result.try(int.parse)
  |> result.unwrap(0)
}

/// `BERYL_API`: `raw` (default) runs the topics through `beryl.child_spec`;
/// `channel` runs the same topics through `beryl/channel` handlers.
pub fn use_channel_layer() -> Bool {
  envoy.get("BERYL_API") == Ok("channel")
}

/// Burn CPU on the calling process for `micros` microseconds.
@external(erlang, "load_test_bench_ffi", "busy_wait")
pub fn burn(micros: Int) -> Nil
