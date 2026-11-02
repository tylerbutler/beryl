# Benchmarks

## Overview

Optional workspace tools measure codec operations apart from sockets and
actors. Start with the [codec package guide](./codec/README.md).
[codec/dev/beryl_codec_bench.gleam:main]

## Subdirectories and boundaries

- [Codec benchmarks](./codec/README.md): package setup, measurement scope,
  the development runner, and preflight fixtures. Glychee/Benchee supply
  the external measurement engine. [codec/gleam.toml:dev-dependencies]
  [codec/manifest.toml:benchee]

## Interface

Use `just bench-codec-deps`, `just bench-codec-check`, and `just bench-codec`
from the repository root. The child package exposes the runner
`beryl_codec_bench.main()` and fixture constructors/validation.
[justfile:bench-codec-deps] [justfile:bench-codec-check]
[justfile:bench-codec] [codec/dev/beryl_codec_bench.gleam:main]
[codec/dev/beryl_codec_bench/fixture.gleam:preflight]

## Invariants

Benchmarks are opt-in workspace members. Default build, check, deps, test,
lint, docs, and release exclude them; formatting and cleanup include them.
Keep this isolation when adding benchmark dependencies.
[../gleam.toml:tools.trellis.members] [../gleam.toml:tools.trellis.exclude]
[justfile:format] [justfile:clean]

## Side effects

Setup installs Elixir/Hex and downloads packages. Checks write build
artifacts and run fixture tests. Measurements consume local resources and
print results without opening benchmark-server sockets.
[justfile:bench-codec-deps] [justfile:bench-codec-check]
[codec/dev/beryl_codec_bench.gleam:main]

## Verification

After the optional setup, run `just bench-codec-check` from the repository
root. Root `just test` does not cover this subtree. Do not run
`just bench-codec` unless you intend to collect measurements.
[justfile:bench-codec-check] [justfile:bench-codec]
[../gleam.toml:tools.trellis.exclude.test]
