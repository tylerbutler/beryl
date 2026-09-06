# beryl_ewe changelog

## v0.2.2 - 2026-08-25

### Dependencies

- Updated beryl to 0.4.1

## v0.2.1 - 2026-08-24

### Dependencies

- Updated beryl to 0.4.0

## v0.2.0 - 2026-08-21

### Changed

- BREAKING: `with_on_connect` now returns ordered connection metadata in `Result(List(#(String, String)), ConnectError)`. Beryl merges this metadata into `ConnectSeed.metadata` instead of treating the callback as a `Nil`-only authentication gate.

### Dependencies

- Updated beryl to 0.3.0

## v0.1.1 - 2026-08-07

### Dependencies

- Updated beryl to 0.2.0

## v0.1.0 - 2026-08-07

### Added

- Initial release: Ewe WebSocket transport for beryl. Mirrors the beryl_mist config-builder and handler API using Ewe request and response types, with socket-level authentication, Origin policies, Phoenix version negotiation, and edge enforcement of frame-size, rate, and connection limits.

### Dependencies

- Update locked Gleam dependencies.
- Updated beryl to 0.1.0
