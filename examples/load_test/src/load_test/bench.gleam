//// Benchmark knobs read from the environment.

import envoy
import gleam/int
import gleam/result

/// Read an integer knob from the environment.
pub fn environment_integer(name: String, default: Int) -> Int {
  envoy.get(name)
  |> result.try(int.parse)
  |> result.unwrap(default)
}

/// `BENCH_CALLBACK_COST_US`: CPU time for each message callback, in
/// microseconds. The default is zero.
pub fn callback_cost_us() -> Int {
  environment_integer("BENCH_CALLBACK_COST_US", 0)
}

/// `BERYL_API`: `raw` (default) runs the topics through `beryl.child_spec`;
/// `channel` runs the same topics through `beryl/channel` handlers.
pub fn use_channel_layer() -> Bool {
  envoy.get("BERYL_API") == Ok("channel")
}

/// Use CPU on the calling process for `microseconds` microseconds.
@external(erlang, "load_test_bench_ffi", "busy_wait")
pub fn burn(microseconds: Int) -> Nil
