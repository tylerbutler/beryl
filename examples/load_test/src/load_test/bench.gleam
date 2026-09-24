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

/// `BENCH_CALLBACK_ELAPSED_US`: minimum elapsed time for each message
/// callback, in microseconds. The default is zero. The wait uses CPU while
/// scheduled, but preemption and suspension count toward the elapsed time.
pub fn callback_elapsed_us() -> Int {
  environment_integer("BENCH_CALLBACK_ELAPSED_US", 0)
}

/// `BERYL_API`: `raw` (default) runs the topics through `beryl.child_spec`;
/// `channel` runs the same topics through `beryl/channel` handlers.
pub fn use_channel_layer() -> Bool {
  envoy.get("BERYL_API") == Ok("channel")
}

/// Busy-wait until `microseconds` have elapsed.
///
/// This is preemptible elapsed-time behavior, not fixed or calibrated CPU work.
@external(erlang, "load_test_bench_ffi", "wait_elapsed")
pub fn wait_elapsed(microseconds: Int) -> Nil
