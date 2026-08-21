# beryl

## Project Overview

Type-safe real-time channels and presence for Gleam, targeting the Erlang
(BEAM) runtime. The repository is a [trellis](https://trellis.tylerbutler.com)-managed
monorepo with three packages (two currently publishable — `beryl_ewe` is
excluded from release via the `@release` key in the root `gleam.toml`):

- **`packages/beryl`** — raw app dispatch plus `beryl/channel` (runtime,
  typed events/effects, presence, PubSub, wire protocol, abuse controls,
  transport SPI)
- **`packages/beryl_mist`** — Mist WebSocket transport (module `beryl_mist`),
  built on the public `beryl/transport` SPI
- **`packages/beryl_ewe`** — Ewe WebSocket transport (module `beryl_ewe`),
  built on the public `beryl/transport` SPI; mirrors the `beryl_mist` API

The root `gleam.toml` is workspace configuration only (`[tools.trellis]`);
per-package manifests live in each package directory.

## Build Commands

Run gleam commands inside a package directory, or use trellis/just from the
root to fan out across the workspace:

```bash
trellis run build        # Compile all packages (in dependency order)
trellis run test         # Run tests in all packages
trellis run check        # Type check
trellis run format       # Format code
trellis run docs         # Build Gleam docs (packages only)
trellis doctor           # Validate workspace invariants
```

## Just Commands

```bash
just deps         # Download dependencies (gleam + pnpm workspaces)
just build        # trellis run build
just build-strict # trellis run build --strict
just test         # trellis run test (scope: `just test beryl_mist`)
just format       # trellis run format
just format-check # trellis run format --check
just check        # trellis run check
just lint         # trellis run lint (glinter; packages only)
just doctor       # trellis doctor
just docs         # Gleam docs + website reference regeneration
just change P K B # trellis changelog new --package P --kind K --body B
just version-plan # Preview next versions from unreleased fragments
just ci           # Run all CI checks (format, check, test, build, examples)
just pr           # Alias for ci (use before PR)
just main         # Extended checks for main branch
just clean        # Remove build artifacts
```

## Project Structure

```
gleam.toml                         # Workspace config only ([tools.trellis])
packages/
├── beryl/                         # Core library package
│   ├── gleam.toml
│   ├── src/
│   │   ├── beryl.gleam            # Main public API (config, child_spec, stop, broadcast)
│   │   ├── beryl_ffi.erl          # Erlang FFI (timing, admission atomics, validated PubSub coercion)
│   │   ├── beryl_pubsub_ffi.erl   # Erlang FFI for pg-based PubSub
│   │   └── beryl/
│   │       ├── bridge.gleam       # Forward external actor streams to typed socket Senders
│   │       ├── connection_limit.gleam  # Connection limit enforcement (internal)
│   │       ├── error.gleam        # Shared error types/helpers
│   │       ├── event.gleam        # Typed app-dispatch events, effects, refs, and senders
│   │       ├── group.gleam        # Named channel groups
│   │       ├── internal.gleam     # Internal helpers (internal)
│   │       ├── log.gleam          # Logging helpers (internal)
│   │       ├── presence.gleam     # Presence tracking (CRDT-backed actor)
│   │       ├── pubsub.gleam       # PubSub abstraction (pg-based)
│   │       ├── rate_limit.gleam   # Rate limiting helpers (internal)
│   │       ├── runtime.gleam      # App-dispatch socket/topic runtime (internal)
│   │       ├── stats.gleam        # Runtime statistics API
│   │       ├── telemetry.gleam    # Internal telemetry schema
│   │       ├── topic.gleam        # Topic pattern matching
│   │       ├── transport.gleam    # Public transport SPI (used by beryl_mist/beryl_ewe)
│   │       ├── wire.gleam         # Wire protocol (JSON encode/decode)
│   │       ├── presence/wire.gleam    # Presence wire format helpers
│   │       └── wire/codec.gleam   # Wire codec helpers
│   └── test/                      # Core tests + Erlang test FFI helpers
├── beryl_mist/                    # Mist WebSocket transport package
│   ├── gleam.toml                 # depends on beryl by path
│   ├── src/beryl_mist.gleam       # Transport implementation
│   └── test/                      # Transport/contract tests + WS client FFI
└── beryl_ewe/                     # Ewe WebSocket transport package
    ├── gleam.toml                 # depends on beryl by path
    ├── src/beryl_ewe.gleam        # Transport implementation
    └── test/                      # Transport/handler tests + WS client FFI
examples/                          # Runnable example apps (workspace members,
                                   # excluded from release) + pnpm/Playwright e2e
website/                           # Astro/Starlight docs site (not a member)
.changes/unreleased/               # trellis changelog fragments (TOML)
```

## Architecture

### Core Layers

1. **App Dispatch Runtime** (`beryl`, `beryl/event`, internal `beryl/runtime`)
2. **PubSub** (`beryl/pubsub`) - pg-based process groups
3. **Presence** - CRDT-backed actor using `lattice_presence/presence_state` (`beryl/presence`)
4. **Groups** (`beryl/group`) - Named channel groups for broadcast
5. **Transport SPI** (`beryl/transport`) - public contract for transports;
   `beryl_mist` and `beryl_ewe` consume only public beryl API

### Dependencies

#### packages/beryl (runtime)
- `gleam_stdlib`, `gleam_erlang`, `gleam_otp`, `gleam_json`, `gleam_crypto`
- `lattice_presence` - Presence CRDTs
- `palabres` - Logging

#### packages/beryl_mist (runtime)
- `beryl` (path dep; rewritten to a Hex requirement at publish)
- `mist`, `gleam_http` - HTTP/WebSocket server integration
- `gleam_stdlib`, `gleam_erlang`, `gleam_crypto`

#### packages/beryl_ewe (runtime)
- `beryl` (path dep; rewritten to a Hex requirement at publish)
- `ewe`, `gleam_http` - HTTP/WebSocket server integration
- `gleam_stdlib`, `gleam_erlang`, `gleam_crypto`

#### Development
- `vouch` - Test runner (gleeunit-compatible; supports `--filter`, JUnit
  output, watch mode)
- `gleeunit` - Assertion library (`gleeunit/should`)
- git-sourced test helpers: `phoenix_channel_fixtures` (beryl),
  `aquamarine`, `gluegun` (beryl_mist)

## Testing

```bash
just test                # All packages
just test beryl_mist     # One package
cd packages/beryl && gleam test   # Directly
```

## Tool Versions

Managed via `.tool-versions` (the floor, and what CI's version-file
resolution uses):
- Erlang 27.2.1
- Gleam 1.16.0
- just 1.50.0

CI matrix-tests Erlang 27 and 28. `.mise.toml` pins `erlang = "28"` for local
development, deliberately overriding `.tool-versions` for mise users.

trellis (0.10.3) is pinned in `.mise.toml` for local development and
installed in CI via `.github/actions/mise`.

## CI/CD

### Workflows
- **ci.yml**: format check, type check, strict build, tests (via trellis),
  docs job (website reference must be up to date), examples job (Playwright)
- **pr.yml**: PR title validation (commitlint), `trellis doctor`,
  `trellis changelog check`
- **release.yml**: `trellis release pr` on push to main
- **publish.yml**: on release-PR merge — `trellis tag create --push
  --github-release` (Hex.pm publishing via `trellis publish` is temporarily
  disabled)

### Release Flow
1. Push commits with conventional commit messages
2. Add changelog fragments with `just change <package> <kind> "<body>"`
3. `trellis release pr` maintains a release PR (branch `release/pending`)
   with version bumps and CHANGELOGs
4. Merge the release PR → per-package tags (`beryl-v1.2.3`) and GitHub
   releases are created (Hex.pm publishing is temporarily disabled — see
   `.github/workflows/publish.yml`)

## Conventions

- Use Result types over exceptions
- Exhaustive pattern matching
- Follow `gleam format` output
- Keep public API minimal
- Document public functions with `///` comments
- beryl's internal modules (`connection_limit`, `internal`, `log`,
  `rate_limit`, `runtime`, `telemetry`) must not be imported by other
  packages; transports use the `beryl/transport` SPI

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(channel): add support for binary messages
fix(presence): handle concurrent leave/join correctly
docs: update installation instructions
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`

See `.commitlintrc.json` for configuration.

## Editor / LSP Setup

The Gleam language server is wired up two ways:

- `.lsp.json` / `.github/lsp.json` — materialized by `apm` from the `lsp`
  entry in `apm.yml`'s `dependencies` (`gleam lsp`, `.gleam` → `gleam`), for
  targets that discover root-level LSP config (e.g. Copilot).
- `.claude-plugin/marketplace.json` + `.claude-plugin/plugin.json` — a local
  Claude Code plugin (`gleam-lsp@beryl`) with `lspServers` inlined. Claude
  Code's `getAllLspServers()` only reads enabled plugins' manifests — there's
  no project-root or user-settings discovery path — so this plugin is what
  actually registers the LSP for Claude Code.

Plugin marketplace registration and enablement state lives in the user's
global `~/.claude/plugins/known_marketplaces.json` and
`installed_plugins.json`, never in the repo, so it can't be checked in. Each
clone needs a one-time:

```bash
claude plugin marketplace add ./
claude plugin install gleam-lsp@beryl
```

LSP tools become available on the next session start.

## Additional Documentation

- **DEV.md**: Detailed development workflows and guidelines
