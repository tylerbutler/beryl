# beryl

## Project Overview

Type-safe real-time channels and presence for Gleam, targeting the Erlang (BEAM) runtime.

## Build Commands

```bash
gleam build              # Compile project
gleam test               # Run tests
gleam check              # Type check without building
gleam format src test    # Format code
gleam docs build         # Generate documentation
```

## Just Commands

```bash
just deps         # Download dependencies
just build        # Build project
just test         # Run tests
just format       # Format code
just format-check # Check formatting
just check        # Type check
just docs         # Build documentation
just ci           # Run all CI checks (format, check, test, build)
just pr           # Alias for ci (use before PR)
just main         # Extended checks for main branch
just clean        # Remove build artifacts
```

## Project Structure

```
src/
├── beryl.gleam                    # Main public API (channels, config, start/register)
├── beryl_ffi.erl                  # Erlang FFI (identity coercion)
├── beryl_pubsub_ffi.erl           # Erlang FFI for pg-based PubSub
└── beryl/
    ├── bridge.gleam               # Bridge between transports and channels
    ├── channel.gleam              # Channel behaviour/callbacks
    ├── connection_limit.gleam     # Connection limit enforcement
    ├── coordinator.gleam          # Channel lifecycle coordinator (OTP actor)
    ├── error.gleam                # Shared error types/helpers
    ├── group.gleam                # Named channel groups
    ├── internal.gleam             # Internal helpers
    ├── log.gleam                  # Logging helpers
    ├── presence.gleam             # Presence tracking (OTP actor wrapping lattice_presence)
    ├── pubsub.gleam               # PubSub abstraction (pg-based)
    ├── rate_limit.gleam           # Rate limiting helpers
    ├── socket.gleam               # Socket abstraction
    ├── supervisor.gleam           # OTP supervision helpers
    ├── topic.gleam                # Topic pattern matching
    ├── transport/
    │   └── mist.gleam             # Mist WebSocket transport integration
    ├── wire.gleam                 # Wire protocol (JSON encode/decode)
    ├── presence/
    │   └── wire.gleam             # Presence wire format helpers
    └── wire/
        └── codec.gleam            # Wire codec helpers
test/
├── *_test.gleam                  # Gleam test modules for public API, transport, presence, etc.
├── *_test_ffi.erl                # Erlang helpers for tests that need BEAM interop
└── test_helpers.gleam            # Shared test helpers
```

## Architecture

### Core Layers

1. **Channel System** (`beryl`, `beryl/channel`, `beryl/coordinator`)
2. **PubSub** (`beryl/pubsub`) - pg-based process groups
3. **Presence** - CRDT-backed actor using `lattice_presence/presence_state` (`beryl/presence`)
4. **Groups** (`beryl/group`) - Named channel groups for broadcast

### Dependencies

#### Runtime
- `gleam_stdlib` - Standard library
- `gleam_erlang` - Erlang interop
- `gleam_otp` - OTP actors
- `gleam_json` - JSON encoding/decoding
- `gleam_crypto` - Cryptographic functions
- `mist` - HTTP/WebSocket server and transport integration

#### Development
- `gleeunit` - Testing framework

## Testing

```bash
just test
# or
gleam test
```

## Tool Versions

Managed via `.tool-versions` (source of truth for CI):
- Erlang 27.2.1
- Gleam 1.16.0
- just 1.50.0

Local development can use `.mise.toml` for flexible versions.

## CI/CD

### Workflows
- **ci.yml**: Format check, type check, build, test
- **pr.yml**: PR title validation (commitlint), changelog entry check (changie)
- **release.yml**: Automated versioning via changie-release
- **auto-tag.yml**: Auto-tag on release PR merge
- **publish.yml**: Publish to Hex.pm on tag push

### Release Flow
1. Push commits with conventional commit messages
2. Add changelog entries with `changie new`
3. changie-release creates a PR with version bump
4. Merge PR → auto-tag creates GitHub release
5. publish.yml triggers → publishes to Hex.pm

## Conventions

- Use Result types over exceptions
- Exhaustive pattern matching
- Follow `gleam format` output
- Keep public API minimal
- Document public functions with `///` comments

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(channel): add support for binary messages
fix(presence): handle concurrent leave/join correctly
docs: update installation instructions
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`

See `.commitlintrc.json` for configuration.

## Additional Documentation

- **DEV.md**: Detailed development workflows and guidelines
