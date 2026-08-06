# Copilot instructions for Beryl

## Project shape

Beryl is a Gleam library for type-safe realtime channels and presence on the Erlang/BEAM target.

- `packages/beryl/src/beryl.gleam` is the main public API for configuring a supervised app-dispatch system with `child_spec`, stopping it, and broadcasting.
- `packages/beryl/src/beryl/event.gleam` defines typed app events/effects; `packages/beryl/src/beryl/runtime.gleam` owns socket/topic lifecycle and dispatches every event through the app's `update`.
- `packages/beryl/src/beryl/pubsub.gleam` wraps Erlang `pg` via `packages/beryl/src/beryl_pubsub_ffi.erl` for distributed broadcasts.
- Presence is the OTP actor in `packages/beryl/src/beryl/presence.gleam`, backed directly by `lattice_presence/presence_state`.
- Core WebSocket transport is Mist-based in `packages/beryl_mist/src/beryl_mist.gleam` (its own package, built on the `beryl/transport` SPI); examples also use Mist directly for HTTP routing/static assets.

## Commands

Prefer the just recipes because they match CI:

```bash
just deps          # install all workspace packages, examples, and JS deps
just check         # Gleam type check
just test          # Gleam test suite
just format        # format src and test
just format-check  # formatting check
just ci            # format-check, check, test, build-strict, examples-test
just pr            # alias for just ci
just main          # just ci plus docs
```

Run a focused Gleam test with:

```bash
gleam test -- --filter "test_name"
```

Example Playwright runs can create untracked test artifacts; clean those before staging unless the task explicitly asks to update them.

## Tooling and dependencies

- `.tool-versions` is the source of truth for Erlang, Gleam, and just versions. Keep `.mise.toml` limited to mise-only helper tools such as trellis/rebar unless the user asks otherwise.
- Avoid declaring the same package in both `[dependencies]` and `[dev-dependencies]`; keep shared requirements in the runtime dependency with the stricter compatible range.
- When changing generated dependency files, update `gleam.toml` and `manifest.toml` consistently with Gleam tooling rather than hand-editing only one side.

## Testing conventions

- BEAM mailbox state matters. PubSub, heartbeat, and WebSocket tests should select the exact message shape they expect and consume or drain messages they create.
- Do not use broad "any message" selectors in tests that run near PubSub or transport assertions; a stale queued message can make the next test fail nondeterministically.
- When replacing WebSocket transports or dependency surfaces, preserve existing Phoenix/WebSocket contract coverage by repurposing tests for the new transport instead of deleting them.
- Public socket/event behavior changes should include integration-level coverage through the runtime and transport paths, not only pure helper tests.

## PR and release workflow

- Before creating or updating a PR, fetch the current default branch and validate the branch against it; PR CI tests the merge result, so local `just ci` on an outdated branch can miss failures.
- PR titles must follow Conventional Commits and should keep type/scope lowercase, for example `fix(pubsub): preserve broadcast_from exclusion`.
- Add a trellis changelog fragment for public API, behavior, dependency, or user-visible changes. Use `just change <package> <kind> "<body>"` (trellis changelog new) instead of inventing changelog filenames.
- Commit only intended source, test, docs, manifest, and changelog fragment files. Do not stage generated Playwright output or temporary PR body files.

## Code conventions

- Keep the public API small and document public functions with `///` comments.
- Use `Result` for fallible APIs and preserve exhaustive pattern matching.
- Follow existing event/effect handling patterns in `event` and `runtime` when adding app-dispatch behavior.
