# AGENTS.md — Working in the Beryl Codebase

## Project Summary

Beryl is a Gleam library for type-safe real-time channels and presence on the
Erlang/BEAM runtime. It's a trellis-managed monorepo with three packages — two
of them currently publishable, since `beryl_ewe` is release-excluded — plus
runnable examples and an Astro/Starlight documentation website.

## Essential Commands

```bash
just deps              # install all deps (gleam + pnpm workspaces)
just check             # type check all packages
just test              # run all tests (scope: `just test beryl_mist`)
just format            # format all packages
just format-check      # check formatting (CI uses this)
just lint              # glinter with warnings_as_errors
just ci                # full CI: format-check, check, test, build-strict, examples-test
just pr                # alias for ci — run before creating/updating PRs
just change P K "B"    # create changelog fragment (trellis changelog new)
just doctor            # validate workspace invariants
```

Run a single test: `cd packages/beryl && gleam test -- --filter "test_name"`

## Workspace Layout and Package Boundaries

```
packages/
  beryl/           # core library (app dispatch, presence, pubsub, wire, transport SPI)
  beryl_mist/      # Mist WebSocket transport (depends on beryl via path)
  beryl_ewe/       # Ewe WebSocket transport (depends on beryl via path; NOT published)
examples/          # runnable example apps (workspace members, excluded from release)
website/           # Astro/Starlight docs site (NOT a workspace member)
docs/              # ADRs, design docs, architecture deck, security docs
```

### Strict Import Boundaries

**Transport packages (`beryl_mist`, `beryl_ewe`) MUST only import from the
public `beryl/transport` SPI module.** They must never import:
- `beryl/connection_limit`
- `beryl/internal`
- `beryl/log`
- `beryl/rate_limit`
- `beryl/runtime`
- `beryl/telemetry`

These modules are declared as `internal_modules` in `packages/beryl/gleam.toml`
and are hidden from the public API. Functions in `beryl/transport` that are
consumed by transport packages carry `// nolint: unused_exports` annotations
because they appear unused within beryl itself.

## Architecture (Non-Obvious)

### Typed App Dispatch

`beryl.child_spec` captures the app's generic `model`, `msg`, `init`, and
`update` types in monomorphic closures behind the opaque `Sockets` handle. The
runtime stores each socket's typed model and delivers `Join`, `Message`,
`Binary`, `Closed`, and typed `Info` events without socket-dispatch casts or
`Dynamic` round-trips. `Dynamic` is limited to decoded wire payloads.

Join `Ref` values are single-pending-join capabilities with unique runtime
identity. Never reconstruct or compare their wire fields; return the exact ref
in `AcceptJoin` or `RejectJoin`.

### Transport SPI Contract

A transport implementation must follow this lifecycle:
1. **Admit**: call `beryl.acquire_connection_slot` + `beryl.bind_connection_slot`
2. **Own**: capture `transport.connection_owner` and monitor an `OwnerAlive` pid
3. **Register atomically**: call `transport.admit_socket` with the captured
   owner and closer; close on failure
4. **Route**: decode inbound frames with `transport.active_codec`, route via
   `transport.route_decoded` / `transport.route_binary`, shed over-rate frames
   with `transport.new_message_limiter` / `transport.take_token`
5. **Disconnect**: `transport.socket_disconnected` + `beryl.release_connection_slot`

### Wire Protocol

The built-in codec (`wire.phoenix_codec()`) implements the Phoenix wire format.
`beryl.config` takes the codec as a required argument — there is no implicit
default.
- Text frames: `[join_ref, ref, topic, event, payload]` JSON arrays
- Binary frames: Phoenix V2 binary framing
- Heartbeats: topic `"phoenix"`, event `"heartbeat"`; replied to with
  `phx_reply` on the same topic

### PubSub Wire Contract

`pubsub.Message(payload)` is sent **raw between BEAM nodes** via `pg`. Its
record tag and four fields (in order) are a frozen wire contract. A rolling
cluster upgrade must not mis-parse a frame from an older node.

### Opaque Types with Builder Pattern

Configuration types (`Config`, `LoggingConfig`, `PubSubConfig`, and presence
`Config`) are opaque. Construct them with their factory functions and adjust
them with `with_*` builders. Never expose or match on their internal fields.

## Testing Gotchas

### BEAM Mailbox State Matters

This is the **most critical testing gotcha**. Tests that run near PubSub,
heartbeat, or WebSocket assertions must:
- Select the **exact** message shape they expect
- Consume or drain messages they create
- **Never** use broad "any message" selectors — a stale queued message from a
  prior test can cause nondeterministic failures

### Polling Over Sleeping

Use `test_helpers.wait_until(check, timeout_ms, interval_ms)` instead of
`process.sleep(N)` for asynchronous assertions (presence replication, broadcast
delivery, etc.).

### Test Scope and Framework

- Tests use `gleeunit` (Gleam's test framework)
- Public socket/event behavior changes need integration coverage through the
  runtime and transport paths, not only pure helper tests
- When replacing WebSocket transports, preserve existing Phoenix/WebSocket
  contract coverage by repurposing tests rather than deleting them

### Erlang Test FFI

Test directories contain `.erl` files for test-only FFI helpers (e.g.,
`beryl_log_capture.erl`, `beryl_supervisor_test_ffi.erl`,
`beryl_mist_transport_test_ffi.erl`). These provide BEAM-level capabilities
not available in pure Gleam.

## Code Conventions

- **Result types over exceptions** — all fallible APIs return `Result`
- **Exhaustive pattern matching** — Gleam enforces this; handle all cases
- **`///` doc comments** on all public functions
- **`@internal` annotation** — hides functions from public docs while keeping
  them accessible to sibling modules within the same package
- **glinter** is enforced with `warnings_as_errors = true`. Key rules:
  `thrown_away_error`, `discarded_result`, `unused_exports`, `deep_nesting`,
  `prefer_guard_clause`, `error_context_lost`, `unqualified_import`,
  `stringly_typed_error`, `short_variable_name`, `string_inspect`

## Commit and Release Workflow

### Conventional Commits

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, `release`, `revert`. Keep type/scope lowercase.
Header max 72 chars. Body max line length 100 chars.

### Changelog Fragments

Use `just change <package> <kind> "<body>"` for any public API, behavior,
dependency, or user-visible change. Kinds: `Initial Release` (major),
`Added`/`Changed`/`Removed` (minor), `Fixed`/`Performance`/`Deprecated`/`Security`/`Dependencies` (patch).

PR CI enforces fragments via `trellis changelog check`.

### Release Flow

1. Push commits with conventional messages + changelog fragments
2. `trellis release pr` maintains a release PR (branch `release/pending`)
3. Merge release PR → per-package tags (`beryl-v1.2.3`) + GitHub releases
4. Hex.pm publishing is temporarily disabled

### Staging Discipline

Do NOT stage: generated Playwright output, `test-results/` directories,
`erl_crash.dump`, temporary PR body files. Example Playwright runs create
untracked artifacts — clean before staging.

## Tooling

### Tool Versions

`.tool-versions` sets the floor and is what CI's version-file resolution uses:
- Erlang 27.2.1, Gleam 1.16.0, just 1.50.0

CI additionally matrix-tests Erlang **27 and 28** (see `.github/workflows/ci.yml`).

`.mise.toml` pins trellis (0.4.1) and rebar for local development, and
deliberately pins `erlang = "28"` so local dev runs on the newer of the two
matrix versions. That pin intentionally overrides `.tool-versions` for mise
users; keep everything else in `.mise.toml` limited to mise-only helper tools.

### Dependency Rules

- Never declare the same package in both `[dependencies]` and `[dev-dependencies]`
- Keep shared requirements in the runtime dependency with the stricter range
- When changing dependency files, update `gleam.toml` and `manifest.toml`
  consistently with Gleam tooling (don't hand-edit one side)

### Trellis Exclusions

`beryl_ewe` is excluded from release (`@release` key in `gleam.toml`) — it's
built, tested, and linted but excluded from changelog, versioning, tagging,
and publishing.

## Examples

Examples are workspace members with their own `gleam.toml`, `package.json`,
and Playwright configs. They depend on beryl via path. The `collab_docs/client`
is a nested workspace member (a JS client). Examples without a `test/`
directory are excluded from `trellis run test` in `gleam.toml`.
