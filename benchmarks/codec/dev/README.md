# Codec benchmark runner

## Overview

Run codec-only measurements with Glychee and its Benchee dependency.
This development entry point does not start a beryl server.
[beryl_codec_bench.gleam:main]

## Interface

- [`beryl_codec_bench.main()`](./beryl_codec_bench.gleam) prepares inputs,
  runs preflight, and submits the operation matrix to Glychee.
  [beryl_codec_bench.gleam:main]
- [Fixture contracts](./beryl_codec_bench/README.md) own input construction,
  validation results, rejection cases, and metadata-boundary checks.
  [beryl_codec_bench/fixture.gleam:preflight]

## Invariants

- Preflight must succeed before measurement. Fixture construction, labels,
  validation, and status output stay outside the timed codec callbacks.
  [beryl_codec_bench.gleam:main]
- The matrix has 40 operation/input pairs: five text fixtures across four
  successful operations; three binary fixtures across four successful
  operations; four text-decode rejections, three binary-decode rejections,
  and one binary-push rejection. The accepted 255-byte metadata boundary
  belongs to preflight, not a timed case. [beryl_codec_bench.gleam:main]
  [beryl_codec_bench/fixture.gleam:check_metadata_boundary]
- Glychee uses one worker, 1 s warmup, 3 s timing, 1 s memory measurement,
  and 1 s reduction measurement. [beryl_codec_bench.gleam:main]

## Side effects

`main()` prints preflight status and runs CPU, memory, and reduction
measurements through Glychee. A failed preflight aborts the run.
[beryl_codec_bench.gleam:main]

## Verification

From the repository root, run `just bench-codec-check` after the optional
setup in the [package guide](../README.md). It does not run measurements.
`just bench-codec` invokes this entry point and consumes benchmark time;
reserve it for an intentional measurement session.
[justfile:bench-codec-check] [justfile:bench-codec]
