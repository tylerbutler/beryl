# Codec fixtures

## Overview

Build and validate the inputs for the optional codec microbenchmarks.
The [fixture module](./fixture.gleam) uses beryl's public wire API.

## Interface

- `Failure(label, reason)`, `TextFixture(label, payload, inbound, frame)`,
  `BinaryFixture(label, payload, frame)`, `RejectionKind` (`JsonError`,
  `FormatError`), and `TextRejection(label, frame, kind)` describe fixture
  values and validation failures. [fixture.gleam:Failure]
  [fixture.gleam:TextFixture] [fixture.gleam:BinaryFixture]
  [fixture.gleam:RejectionKind] [fixture.gleam:TextRejection]
- `text()` returns `Result(List(TextFixture), Failure)`; `binary()`,
  `rejected_text()`, and `rejected_binary()` return their fixture lists.
  [fixture.gleam:text] [fixture.gleam:binary]
  [fixture.gleam:rejected_text] [fixture.gleam:rejected_binary]
- `preflight(...)` returns `Result(Nil, Failure)` after checking the supplied
  fixtures and the metadata-length boundary. [fixture.gleam:preflight]

## Invariants

- Text fixtures cover ASCII body lengths 128, 4096, and 65536 bytes and
  nested-array depths 8 and 64. Labels distinguish body, serialized JSON,
  and complete-frame byte counts. Binary fixtures use the same three
  payload lengths in client-push frames. [fixture.gleam:text]
  [fixture.gleam:binary]
- Rejection inputs cover malformed JSON, incorrect shape, invalid topic
  type, depth 65, truncated binary metadata, unsupported binary kind, and
  invalid UTF-8 topic. [fixture.gleam:rejected_text]
  [fixture.gleam:rejected_binary]
- Preflight checks decoded values, text encoder output, byte-exact server
  binary layouts, rejection variants, and accepted 255-byte versus rejected
  256-byte metadata. Client decoding and server encoding use different
  layouts. [fixture.gleam:check_text] [fixture.gleam:check_binary]
  [fixture.gleam:check_metadata_boundary]

## Side effects

None beyond allocating and returning fixture values and results. The module
does not perform I/O or measurements. [fixture.gleam:text]
[fixture.gleam:preflight]

## Verification

From the repository root, run `just bench-codec-check` after the optional
toolchain/dependency setup in the [package guide](../../README.md).
The recipe checks formatting, builds with warnings as errors, and runs fixture
tests without measurements. Root `just test` excludes this package.
[justfile:bench-codec-check]
[../../../../gleam.toml:tools.trellis.exclude.test]
