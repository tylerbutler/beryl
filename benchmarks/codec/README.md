# Codec benchmarks

Measure the cost of beryl's Phoenix codec without sockets or actors.
[Glychee](https://github.com/inoas/glychee) runs the measurements through
Benchee. Use the [k6 suite](../../load/README.md) for end-to-end latency,
contention, and capacity.

## Overview

This optional Erlang-target package keeps codec measurement dependencies out
of released packages. The [development runner](./dev/README.md) owns the
measurement matrix; its [fixture module](./dev/beryl_codec_bench/README.md)
owns input construction and correctness checks. The runner and fixtures use
Gleam; Elixir enters through the external Glychee/Benchee toolchain.
[gleam.toml:name] [gleam.toml:dev-dependencies]
[dev/beryl_codec_bench.gleam:main] [manifest.toml:benchee]

## Subdirectories and boundaries

- [Development code](./dev/README.md) contains the measurement entry point
  and delegates fixture construction/validation to its child module.
  [dev/beryl_codec_bench.gleam:main]
  [dev/beryl_codec_bench/fixture.gleam:preflight]

## Interface

- Package `beryl_codec_bench` depends on the local beryl package,
  `gleam_stdlib`, and `gleam_json`; Glychee and the test runners are
  development dependencies. [gleam.toml:dependencies]
  [gleam.toml:dev-dependencies]
- `beryl_codec_bench.main()` is the measurement entry point.
  See the [runner contract](./dev/README.md) for its boundary.
  [dev/beryl_codec_bench.gleam:main]

## Invariants

- Preflight checks precede timed measurements; comparisons must use matching
  operations and input labels. The runner supplies one worker and the fixed
  measurement phases described below. [dev/beryl_codec_bench.gleam:main]
- Default workspace build, check, dependency preparation, test, lint, docs,
  and release exclude benchmarks. Formatting and cleanup still include them.
  Use the dedicated recipes for this package.
  [../../gleam.toml:tools.trellis.exclude] [justfile:bench-codec-check]

## Side effects

- `just bench-codec-deps` installs the optional Elixir toolchain and Hex,
  downloads dependencies, and updates local dependency/build state.
  [justfile:bench-codec-deps]
- `just bench-codec-check` writes build outputs and runs fixture tests;
  `just bench-codec` prints provenance and consumes CPU and memory while
  measuring codec operations. Neither recipe starts a load-test server.
  [justfile:bench-codec-check] [justfile:bench-codec]
  [dev/beryl_codec_bench.gleam:main]

## Verification

From the repository root, use `just bench-codec-check` after
`just bench-codec-deps`. This optional check runs formatting validation,
a warnings-as-errors build, and fixture tests without measurements.
It is separate from root `just test` and CI. Setup downloads packages;
the measurement recipe is not a documentation check.
[justfile:bench-codec-deps] [justfile:bench-codec-check]
[../../gleam.toml:tools.trellis.exclude.test]

## Setup and commands

Install the root mise toolchain first. The dependency-preparation script
also needs Node.js 22.12 or later, as does `just deps-gleam`.
From the repository root:

```sh
just bench-codec-deps
just bench-codec-check
just bench-codec
```

`bench-codec-deps` installs Elixir `1.20.4-otp-28` through mise, installs Hex
if missing, and downloads the benchmark's Gleam dependencies. It reuses the
workspace's dependency preparation and path-fingerprint checks. If mise asks
you to trust the local configuration, inspect and trust
`benchmarks/codec/.mise.toml`, then repeat the command.

mise selects tools from this directory's configuration and the root
configuration. Gleam and Hex manage package dependencies, including Glychee
and Benchee. Elixir is not added to the root toolchain.

`bench-codec-check` checks formatting, builds with Gleam warnings as errors,
and runs the fixture tests. It does not run measurements.
`bench-codec` prints the commit and tool versions, checks fixture correctness,
and runs the full matrix in Gleam's development mode. Setup failures are not
benchmark results; run `just bench-codec-deps` before retrying.

## Measurements

| Group | Operations | Inputs |
|---|---|---|
| Text decode | `wire.decode_message` | Event frames with 128 B, 4 KiB, and 64 KiB bodies; nested arrays at depths 8 and 64 |
| Text encode | `wire.encode`, `wire.push`, `wire.reply_json` | The same prebuilt payloads and inbound values |
| Binary decode | `wire.decode_binary_message` | Client-push frames with 128 B, 4 KiB, and 64 KiB payloads |
| Binary encode | `wire.binary_push`, `wire.binary_reply`, `wire.binary_broadcast` | The same prebuilt binary payloads |
| Text rejection | `wire.decode_message/reject` | Malformed JSON, incorrect array shape, invalid topic type, and depth 65 |
| Binary rejection | `wire.decode_binary_message/reject`, `wire.binary_push/reject` | Truncated metadata, unsupported kind, invalid UTF-8 topic, and a 256-byte topic |

The text size cases contain an ASCII `body` field. `body_bytes` counts its
value, not its JSON object or Phoenix framing. Labels also report serialized
JSON and input-frame byte counts. Binary labels report payload and
client-frame byte counts. Nested cases are labeled by array depth.

Every run checks decoded fields and payloads, text encoder output, byte-exact
server binary layouts, expected rejection variants, and the 255/256-byte
metadata boundary. Client and server binary layouts differ; server encoder
output is not validated with the client-push decoder.

The runner uses one worker, a 1-second warmup, a 3-second timing phase,
a 1-second memory phase, and a 1-second reduction phase. Fixtures, validation,
labels, and output are outside the timed codec calls. Results stay on the
console; redirect output to a local file to retain it.

## Compare results

Record the commit, working-tree changes, hardware, OTP/Gleam/Elixir versions,
and scheduler flags. Use the same execution mode and a quiet host. Repeat
each comparison at least three times and compare medians and spread, not the
best run. Keep the toolchain and input labels with each result.

Compare the same operation and fixture across commits. Different frame types
and operations do different work; their side-by-side results do not establish
an equivalent-work text-versus-binary speedup.

Memory statistics estimate process-heap allocation. They exclude
reference-counted binaries' off-heap backing storage, so they cannot show
total allocated bytes or prove that a binary payload was not copied. They
also do not report retained VM memory or RSS. Reductions cover the measured
process, not work in other actors. These numbers do not measure total server
cost, network latency, or capacity.
Benchee may warn that Elixir protocols are not consolidated in the
Gleam-managed build. Retain that warning with the results; do not treat this
setup as a benchmark of Elixir protocol performance.

## Workspace behavior

`beryl_codec_bench` is a workspace member. Default dependency preparation,
build, check, test, lint, docs, and release tasks exclude it. Root
`mise install` does not install its Elixir toolchain. Workspace formatting
and cleanup still include it. Benchmark dependencies and measurements are
not part of CI.

Use the dedicated recipes to build and test this package. It has no releases
or changelog fragments, and no released package depends on Glychee or Benchee.
