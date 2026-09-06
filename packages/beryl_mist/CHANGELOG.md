# beryl_mist changelog

## v0.3.2 - 2026-08-25

### Dependencies

- Updated beryl to 0.4.1

## v0.3.1 - 2026-08-24

### Dependencies

- Updated beryl to 0.4.0

## v0.3.0 - 2026-08-21

### Changed

- BREAKING: `with_on_connect` now returns connection metadata merged into `ConnectSeed.metadata` instead of app-typed assigns. The app receives the request path, query, headers, and metadata through `ConnectInfo.seed`.
- BREAKING: Use `beryl/transport/server` and `beryl/transport/origin` for shared transport configuration. `upgrade_connection` is removed; use `upgrade` or `handler` so every connection runs origin, capacity, and authentication checks.

### Dependencies

- Updated beryl to 0.3.0

## v0.2.0 - 2026-08-07

### Changed

- Pass the upgrade request's path, query, and headers to beryl as a `ConnectSeed`, so app-dispatch systems (`beryl.start_app`) receive request data in `init`.

### Fixed

- Route codec-decoded binary frames through Beryl's binary-classified runtime path so telemetry distinguishes them from text frames.

### Dependencies

- Updated beryl to 0.2.0

## v0.1.0 - 2026-08-07

### Added

- Initial release: Mist WebSocket transport for beryl. Single-listener handler composing channels with an HTTP fallback, socket-level on_connect authentication seeding typed assigns, Origin policies (same-origin by default, allow-list, or allow-all) mitigating cross-site WebSocket hijacking, Phoenix ?vsn negotiation at the handshake, upgrade request path/query/headers delivered to app-dispatch (`beryl.start_app`) `init`, and edge enforcement of frame-size limits, message rate limits, and per-IP/node-wide connection ceilings before any coordinator state is allocated.

### Dependencies

- Update locked Gleam dependencies.
- Updated beryl to 0.1.0
