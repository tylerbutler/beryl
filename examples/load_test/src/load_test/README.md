# Benchmark app modules

## Overview

These modules provide shared channel behavior and HTTP statistics for the
Mist and Ewe benchmark entry points.

## Interface

- `app.gleam:App`, `start`, `port`, and `bind_address` configure and start the app.
- `channel.gleam:init`, `update`, and `message_effects` implement raw dispatch;
  `handlers` supplies the
  composed-channel equivalent.
- `bench.gleam:environment_integer`, `callback_elapsed_us`, `use_channel_layer`, and `wait_elapsed`
  expose benchmark controls.
- `http.gleam:EndpointResult`, `health`, `stats`, and `stats_error` build responses;
  `ewe.gleam:handle` and `mist.gleam:handle` adapt routing, with
  `endpoint_to_response` in each adapter. `runtime_snapshot.gleam:Snapshot` and `snapshot` read
  BEAM statistics through the local Erlang FFI.

## Invariants

- `channel.gleam:update` and `handlers` accept `bench:*` and reject
  `guardrail:forbidden`.
- `app.gleam:port` defaults to 8000; `bind_address` defaults to `127.0.0.1`.
- `bench.gleam:use_channel_layer` selects composed handlers for `BERYL_API=channel`.
- `ewe.gleam:handle` and `mist.gleam:handle` serve `/health` and `/stats`;
  unmatched paths return 404.

## Side effects

- `app.gleam:start` starts session presence and supervision.
- `bench.gleam:wait_elapsed` invokes a monotonic-deadline busy wait through
  Erlang FFI. This measures elapsed delay, not calibrated CPU work.
- `runtime_snapshot.gleam:snapshot` reads process, port, memory, run-queue,
  scheduler, and runtime-version statistics.

## Verification

From the repository root: `cd examples/load_test && gleam build`.
See the [server guide](../../README.md) for runtime/load commands.
