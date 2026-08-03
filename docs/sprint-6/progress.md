# Sprint 6 progress

## Phase 1: protocol and configuration helpers

- Added strict Phoenix V2 five-element text frame encoding and decoding.
- Added monotonically increasing, per-client message refs.
- Added environment configuration validation and URL construction.
- Added framework-free Node checks for k6-independent helpers.
- No blocking GitHub issue applies to this isolated load-client work.
- `PROJECT_BRIEF.md` and an in-repository sprint plan are not present; the
  Producer-provided saved plan is the source of scope.

## Phase 2: k6 client lifecycle and metrics

- Added a `k6/websockets` client with correlated joins, pushes, replies, leaves,
  and graceful shutdown.
- Added heartbeat scheduling and reply tracking, operation timeouts, and
  complete interval/timeout cleanup on leave or close.
- Added observable decode, protocol, unmatched-ref, rejection, timeout, socket,
  and callback errors.
- Added tagged k6 Trend, Counter, Rate, and Gauge metrics without target-specific
  behavior or remote imports.

## Phase 3: validation and handoff

- Node syntax checks pass for all pure and k6-only modules.
- Framework-free helper checks cover config, URL construction, refs, frames,
  replies, malformed input, and heartbeat timeout validation.
- k6 is not installed in the development environment, so no live WebSocket
  smoke run was possible in this phase.
- The full smoke and load scenario matrix remains intentionally deferred to the
  later scenario-profiles todo.

## Telemetry foundation

- Added the Erlang `telemetry` runtime dependency through Gleam tooling.
- Added disabled-by-default public `beryl.with_telemetry` configuration and
  propagated the flag into coordinator configuration without instrumenting
  coordinator or transport paths.
- Added typed internal event helpers, closed metadata vocabularies, monotonic
  duration and mailbox helpers, and the Erlang `telemetry:execute/3` FFI.
- Added focused config, helper, enabled-emission, and disabled-emission tests.
