# Benchmark server entry points

## Overview

The Mist and Ewe executables host the same benchmark app and HTTP endpoints.

## Interface

- `load_test_mist.gleam:main` and `load_test_ewe.gleam:main` start the transports.
- `load_test_bench_ffi.erl:wait_elapsed` supplies benchmark delay.
- `load_test_runtime_snapshot_ffi.erl:snapshot` supplies BEAM statistics.
- [Shared app modules](./load_test/README.md) own benchmark behavior.

## Invariants

- Both entry points mount the WebSocket transport at `/socket`.
- `load_test/app.gleam:port` and `bind_address` default to `127.0.0.1:8000`;
  environment variables can override them.
- `load_test_bench_ffi.erl:wait_elapsed` returns immediately for nonpositive
  durations and otherwise waits against a monotonic deadline.

## Side effects

- Each `main` starts a listener, prints its address, and sleeps indefinitely.
- The FFI reads runtime counters or busy-waits to model callback delay.

## Verification

From the repository root: `cd examples/load_test && gleam build`.
