# Workspace scripts

## Overview

These scripts prepare Gleam dependencies, enforce the portable production
dependency boundary, and analyze compiled Erlang FFI. Invoke the root
`justfile` recipes when they provide build prerequisites.

## Interface

| File | Export or command boundary |
|---|---|
| [Dependency preparation](./prepare-gleam-deps.mjs) | `retryHexRateLimits(operation, retryDelays)`, `prepareDependencies(directory, pathDependencyCount)`, `selectDependencyMembers(members, names)`, and `prepareWorkspaceDependencies(root, names)`; direct execution accepts optional workspace or standalone fixture names. [prepare-gleam-deps.mjs:retryHexRateLimits] [prepare-gleam-deps.mjs:prepareDependencies] [prepare-gleam-deps.mjs:selectDependencyMembers] [prepare-gleam-deps.mjs:prepareWorkspaceDependencies] |
| [Portable dependency check](./check-portable-deps.mjs) | `productionGraph(root, loadPackage)`; direct execution checks `packages/beryl_protocol` and `examples/portable_channels`. [check-portable-deps.mjs:productionGraph] [check-portable-deps.mjs:check] |
| [Dialyzer check](./check-ffi-dialyzer.sh) | `just dialyzer`, with `build-strict` prerequisite; the script scans package Erlang sources and analyzes them against compiled beams. [justfile:dialyzer] [check-ffi-dialyzer.sh:--src] |
| [Xref check](./check-ffi-xref.sh) | `just xref`, with `build-strict` prerequisite; `XREF_BEAMS` carries selected compiled FFI modules into the Erlang subprocess. [justfile:xref] [check-ffi-xref.sh:XREF_BEAMS] |

## Invariants

- Dependency preparation requires Node.js 22.12+ for `globSync`, plus
  `trellis` and Gleam on `PATH`. Default selection omits benchmark members;
  explicit package names may select them and unknown names fail.
  The shared preparation also includes registered standalone fixtures outside
  the Trellis graph. Their pass budget counts transitive local dependencies.
  [prepare-gleam-deps.mjs:globSync]
  [prepare-gleam-deps.mjs:selectDependencyMembers]
- Hex rate limits retry after 10, 30, and 60 seconds. Other failures
  propagate. Dependency preparation allows `pathDependencyCount + 2` passes
  to stabilize manifest/fingerprint state; an incompatible lock retry restores
  the saved manifest if that retry fails.
  [prepare-gleam-deps.mjs:RETRY_DELAYS_MS]
  [prepare-gleam-deps.mjs:retryHexRateLimits]
  [prepare-gleam-deps.mjs:prepareDependencies]
  [prepare-gleam-deps.mjs:downloadDependencies]
- The portable production graph permits `beryl_protocol`,
  `portable_channels`, `gleam_stdlib`, `gleam_json`, and `roost`; an
  unreviewed transitive dependency fails the check. Graph output is sorted.
  [check-portable-deps.mjs:productionGraph]
- FFI analysis requires compiled package beams and fails when it finds no
  Erlang FFI sources. Xref succeeds only when `undefined_function_calls`
  returns an empty list. [check-ffi-dialyzer.sh:--input_list_file]
  [check-ffi-xref.sh:undefined_function_calls]

## Side effects

- Dependency preparation invokes `trellis list --json` and
  `gleam deps download`, may contact Hex, waits during retries, and updates
  manifests and dependency caches. [prepare-gleam-deps.mjs:downloadDependencies]
  [prepare-gleam-deps.mjs:dependencyState]
- The portable check invokes `gleam export package-information`, reads package
  metadata, prints graphs, and creates a temporary directory that it removes
  in `finally`. [check-portable-deps.mjs:check]
- Dialyzer writes source/context lists and a PLT under
  `build/beam-check/<package>/` and launches `dialyzer`. Xref launches `erl`
  and reads compiled beams. Both print diagnostics; their wrapper recipes
  first build packages. [check-ffi-dialyzer.sh:--output_plt]
  [check-ffi-xref.sh:XREF_BEAMS] [justfile:build-strict]

## Verification

From the repository root:

- `just deps-test` exercises dependency preparation helpers.
  It checks standalone fixture lock refresh after local dependency version
  bumps and artifact transfer of fixture locks, fingerprints, and symlinks.
  [justfile:deps-test]
- `node --test scripts/check-portable-deps.test.mjs` exercises the portable
  graph helper. `just portable-host-test` also runs the portable-host tests
  and the live package-metadata boundary check.
  [justfile:portable-host-test]
- `just beam-check` builds packages and runs Dialyzer/Xref; install the root
  BEAM/Gleam toolchain and prepare dependencies first. The analysis writes
  build artifacts. [justfile:beam-check] [justfile:dialyzer] [justfile:xref]
- `just namespace-test` prepares dependencies, clean-builds, and runs the standalone
  `fixtures/heirloom_namespace` consumer. Its own `heirloom` Gleam module and
  `heirloom_ffi` Erlang helper must coexist with beryl. The fixture is outside
  the workspace and release graph. [justfile:namespace-test]
  The release workflow runs this check after version bumps and commits the
  fixture lock with the generated API reference.

`just deps-gleam` is dependency setup, not an offline test; it can download
packages and also prepares website snippets. [justfile:deps-gleam]
