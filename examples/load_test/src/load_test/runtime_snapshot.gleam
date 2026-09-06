pub type Snapshot {
  Snapshot(
    process_count: Int,
    port_count: Int,
    memory_bytes: Int,
    run_queue: Int,
    schedulers_online: Int,
    runtime_version: String,
  )
}

@external(erlang, "load_test_runtime_snapshot_ffi", "snapshot")
pub fn snapshot() -> Result(Snapshot, Nil)
