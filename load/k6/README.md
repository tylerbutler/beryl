# k6 suite

## Overview

[`run.js`](./run.js) is the single k6 entry point. It loads a profile,
validates environment inputs, and delegates to workload functions.
The [load-testing guide](../README.md) explains target setup, profile
settings, measurement limits, and distributed runs.
[run.js:options]

## Subdirectories and boundaries

- [Client and helpers](./lib/README.md): Phoenix lifecycle, framing,
  configuration, metric recording, and result-value construction.
  [lib/phoenix.js:PhoenixClient] [lib/results.js:buildSummary]
- [Workloads](./scenarios/README.md): the eight scenario implementations
  and their terminal checks. [scenarios/workloads.js:protocolSmoke]
  [scenarios/workloads.js:guardrailValidation]

Profile JSON files supply runtime inputs that the entry point loads during
initialization. [run.js:options]

## Interface

- `options` configures one selected scenario. Exported entry functions are
  `protocolSmoke`, `idleConnections`, `connectionRate`, `pushRoundTrip`,
  `broadcastFanout`, `presenceChurn`, `mixedWsHttp`, and
  `guardrailValidation`. `handleSummary(data)` returns the serialized output
  mapping for k6. [run.js:options] [run.js:protocolSmoke]
  [run.js:idleConnections] [run.js:connectionRate] [run.js:pushRoundTrip]
  [run.js:broadcastFanout] [run.js:presenceChurn] [run.js:mixedWsHttp]
  [run.js:guardrailValidation] [run.js:handleSummary]
- [`renderSmokeComment(directory, runUrl)`](./render-smoke-comment.mjs)
  reads stored summaries and returns Markdown. Its Node CLI accepts the
  summary directory and optional run URL and writes to stdout.
  [render-smoke-comment.mjs:renderSmokeComment]
- The [package scripts](./package.json) expose `syntax` and `check`;
  these run under Node without a target server. [package.json:scripts]

## Invariants

- `PROFILE` defaults to `protocol-smoke`; unknown names fail before scenario
  execution. The entry point loads profiles and configuration during module
  initialization. [run.js:options] [lib/profile.js:PROFILE_NAMES]
- Profile and client validation precede workload execution; Node alone cannot
  execute modules that import `k6` APIs. [lib/profile.js:parseProfile]
  [lib/scenario-config.js:loadScenarioConfig]
  [lib/phoenix.js:PhoenixClient]
- Summary construction wraps metadata and the complete k6 result. Its default
  output path is `load/results/<profile>-summary.json`; select a unique
  `SUMMARY_PATH` per run to avoid overwriting results.
  [run.js:handleSummary] [lib/results.js:buildSummary]
  [lib/results.js:summaryPath]
- The smoke-comment renderer expects four runtime/transport combinations;
  missing summaries prevent an all-passed report.
  [render-smoke-comment.mjs:renderSmokeComment]

## Side effects

The k6 entry point reads local profiles through `open()`. Workloads generate
WebSocket traffic and, for the mixed scenario, HTTP requests.
`handleSummary` supplies output for k6 to write to disk. The Node smoke
renderer reads summary files and writes Markdown to stdout when run as a
CLI; it does not post a GitHub comment.
[run.js:options] [run.js:handleSummary]
[scenarios/workloads.js:mixedWsHttp]
[render-smoke-comment.mjs:findSummaries]
[render-smoke-comment.mjs:renderSmokeComment]

## Verification

From the repository root:

- `just load-syntax`: Node parsing, no target traffic.
- `just load-helpers`: local configuration, protocol, lifecycle, profile,
  and renderer checks.
- `just load-check [profile]`: the above checks plus inspection with Docker
  image `grafana/k6:2.1.0`, which may require an image download.

These commands match the root recipes and `package.json`; inspection uses
placeholder targets without contacting them. [justfile:load-syntax]
[justfile:load-helpers] [justfile:load-check] [package.json:scripts]

For intentional traffic use `just load-run <profile> <target> <transport>`
after the [setup instructions](../README.md#k6-setup). It requires a running
compatible target and Docker networking that can reach it. It creates
`load/results` and mounts the repository for output. [justfile:load-run]
