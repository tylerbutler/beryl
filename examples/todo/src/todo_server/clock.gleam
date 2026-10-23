//// VM-local monotonic time for actor call deadlines.

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int

/// Return monotonic milliseconds, with an arbitrary (possibly negative) origin.
/// Compare deadlines only with readings from this VM, never with wall time.
pub fn monotonic_milliseconds() -> Int {
  monotonic_time(Millisecond)
}
