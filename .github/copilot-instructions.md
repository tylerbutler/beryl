# Copilot instructions for Beryl

## Project shape

Beryl is a Gleam library for type-safe realtime channels and presence on the Erlang/BEAM target.

- `src/beryl.gleam` is the main public API for starting/registering channels and broadcasting.
- `src/beryl/channel.gleam` defines typed channel callbacks; `src/beryl/coordinator.gleam` owns socket/topic lifecycle and callback dispatch.
- `src/beryl/pubsub.gleam` wraps Erlang `pg` via `src/beryl_pubsub_ffi.erl` for distributed broadcasts.
- Presence is split between the OTP actor in `src/beryl/presence.gleam` and the pure CRDT state in `src/beryl/presence/state.gleam`.
- Core WebSocket transport is Mist-based in `src/beryl/transport/mist.gleam`. Wisp may appear in examples for HTTP routing/static assets, but do not reintroduce Wisp as the core transport dependency.

## Commands

Prefer the just recipes because they match CI:

```bash
just deps          # install root, examples, and example JS deps
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

- `.tool-versions` is the source of truth for Erlang, Gleam, and just versions. Keep `.mise.toml` limited to mise-only helper tools such as changie/rebar unless the user asks otherwise.
- Avoid declaring the same package in both `[dependencies]` and `[dev-dependencies]`; keep shared requirements in the runtime dependency with the stricter compatible range.
- When changing generated dependency files, update `gleam.toml` and `manifest.toml` consistently with Gleam tooling rather than hand-editing only one side.

## Testing conventions

- BEAM mailbox state matters. PubSub, heartbeat, and WebSocket tests should select the exact message shape they expect and consume or drain messages they create.
- Do not use broad "any message" selectors in tests that run near PubSub or transport assertions; a stale queued message can make the next test fail nondeterministically.
- When replacing WebSocket transports or dependency surfaces, preserve existing Phoenix/WebSocket contract coverage by repurposing tests for the new transport instead of deleting them.
- Public channel behavior changes should include integration-level coverage through the coordinator path, not only pure helper tests.

## PR and release workflow

- Before creating or updating a PR, fetch the current default branch and validate the branch against it; PR CI tests the merge result, so local `just ci` on an outdated branch can miss failures.
- PR titles must follow Conventional Commits and should keep type/scope lowercase, for example `fix(pubsub): preserve broadcast_from exclusion`.
- Add a changie fragment for public API, behavior, dependency, or user-visible changes. Use `just change` or the repo changie workflow instead of inventing changelog filenames.
- Commit only intended source, test, docs, manifest, and changie files. Do not stage generated Playwright output or temporary PR body files.

## Code conventions

- Keep the public API small and document public functions with `///` comments.
- Use `Result` for fallible APIs and preserve exhaustive pattern matching.
- Follow existing callback/result handling patterns in `channel` and `coordinator` when adding new channel behavior.
