# beryl

Type-safe app-side real-time sockets and presence for Gleam on the BEAM.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready. We welcome
> usage and feedback in the meantime!

## Overview

beryl is the core real-time library. Applications can use raw app-side
dispatch with one `init`/`update` pair, or the `beryl/channel` handler layer.
Both share the Phoenix-compatible wire protocol, topic matching, broadcasts,
CRDT-backed presence, pg-based PubSub, and built-in abuse controls.

To serve sockets over WebSockets, pair it with a transport package such as
[`beryl_mist`](https://github.com/tylerbutler/beryl/tree/main/packages/beryl_mist).
beryl packages are currently distributed from GitHub, not Hex:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl" }
beryl_mist = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_mist" }
```

Use the same git ref for beryl and your transport package. See the
[installation guide](https://beryl.tylerbutler.com/installation/) for Ewe,
API-choice, and release-tag guidance.

beryl targets the **Erlang/BEAM** runtime only. It does not support the
JavaScript target.

## Interface

- `beryl.config(codec)` and `beryl.child_spec` build typed app dispatch;
  configuration builders set limits, PubSub, presence, logging, and telemetry.
  `stop`, `broadcast`, `broadcast_from`, and `broadcast_presence_diff` operate
  on opaque `Sockets` (`src/beryl.gleam:config`, `src/beryl.gleam:child_spec`,
  `src/beryl.gleam:stop`, `src/beryl.gleam:broadcast`,
  `src/beryl.gleam:broadcast_from`, `src/beryl.gleam:broadcast_presence_diff`).
- [Source contracts](./src/README.md) index the entry module, native support,
  and nested socket/channel, presence, PubSub, wire, and transport APIs.
- The package depends on the workspace `beryl_protocol` package. The root
  workspace bundles that dependency into beryl releases
  (`gleam.toml:dependencies`, `/gleam.toml:tools.trellis.publish.bundle`).
- Manifest `internal_modules` and declaration-level `@internal` annotations
  exclude runtime helpers from the supported API
  (`gleam.toml:internal_modules`, `src/beryl.gleam:app_dispatch`).

## Invariants

- Supply a codec; beryl has no implicit default
  (`src/beryl.gleam:config`).
- Start the returned child specification under supervision. Name-backed
  handles remain stable across runtime restarts
  (`src/beryl.gleam:build_app_subtree`, `src/beryl.gleam:child_spec_supervisor`).
- Return exact join/reply capability values. Effects run in list order;
  presence operations pause the socket's remaining effects until resolution
  (`src/beryl/socket.gleam:JoinReference`,
  `src/beryl/socket.gleam:ReplyReference`, `src/beryl/runtime.gleam:run_effects`).
- Keep local presence diffs local. PubSub participants sharing a scope require
  compatible payload representations and the scoped five-element wire tuple
  (`src/beryl/presence.gleam:DiffScope`, `src/beryl/pubsub.gleam:start`,
  `src/beryl/pubsub.gleam:send_to_pid`).

## Side effects

Starting the child specification creates supervised actors, queues, monitors,
and timers. Runtime operations invoke application callbacks, send frames,
publish through pg/PubSub, and update configured presence. Native helpers
maintain ETS/atomic state and emit diagnostics; beryl does not configure the
host's OTP Logger (`src/beryl.gleam:child_spec_supervisor`,
`src/beryl/runtime.gleam:execute_socket_update`,
`src/beryl/runtime.gleam:send_frame`, `src/beryl/presence.gleam:do_track`,
`src/beryl/pubsub.gleam:broadcast`, `src/beryl/log.gleam:emit`).

## Verification

From the repository root: `just test beryl` includes the core parallel, serial,
and distributed test lanes. Use `just protocol-test` for the bundled protocol
on both targets, and `just beam-check` for Erlang FFI boundaries.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package API: <https://beryl.tylerbutler.com/reference/api/beryl/>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl`)

## Writing a custom transport

The `beryl/transport` module is the public SPI for transport authors: socket
lifecycle announcements, inbound routing, codec access, and per-connection
rate limiting. `beryl_mist` is the reference implementation.

## Licence

MIT
