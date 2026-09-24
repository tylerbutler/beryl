# Development Guide

This document provides detailed instructions for developing and contributing to this project.

## Prerequisites

Ensure you have the following installed:

| Tool | Version | Purpose |
|------|---------|---------|
| Erlang/OTP | 27.2.1+ | BEAM runtime |
| Gleam | 1.16.0+ | Compiler and tooling |
| just | 1.50.0+ | Task runner |
| [trellis](https://trellis.tylerbutler.com) | 0.10.3+ | Gleam workspace manager (tasks, versions, publishing) |

**Recommended:** Use [mise](https://mise.jdx.dev/) or [asdf](https://asdf-vm.com/) with the provided `.tool-versions` file. trellis is pinned in `.mise.toml` (mise's GitHub backend); it can also be installed via its shell installer or Homebrew. Note that `.mise.toml` also pins `erlang = "28"`, so mise users build on Erlang 28 while `.tool-versions` sets the 27.2.1 floor; CI matrix-tests both.

This repository is a trellis-managed workspace: three packages live under
`packages/` — `beryl`, `beryl_mist`, and `beryl_ewe` — with
runnable examples in `examples/` and a root `gleam.toml` holding only the
`[tools.trellis]` configuration. `beryl_ewe` is built, tested, and linted but
excluded from release via the `@release` key, so the other two packages are
publishable. `just` recipes fan out across the workspace through `trellis run`.

```bash
# With mise
mise install

# With asdf
asdf install
```

## Getting Started

```bash
# Clone the repository
git clone <repo-url>
cd beryl

# Install dependencies
just deps

# Verify everything works
just ci
```

`just deps-gleam` uses Node.js 22.12+ to prepare workspace and documentation
snippet dependencies in sequence. Gleam 1.18.1 updates only one changed path
dependency fingerprint per call. Preparation repeats until the manifest and
fingerprints stop changing, retries Hex rate-limit failures with bounded
backoff, then CI caches that state for all jobs. This workaround can be removed
when the pinned Gleam release includes
[gleam-lang/gleam#6246](https://github.com/gleam-lang/gleam/pull/6246).
Run `just deps-test` to check cold preparation, changed dependencies, and cache reuse.

## Development Workflow

### Daily Development

```bash
# Check your code compiles
just check

# Run tests
just test

# Run Dialyzer and Xref against Erlang FFI
just beam-check

# Format code (do this before committing)
just format
```

### Before Committing

```bash
# Run full CI checks locally
just pr
```

### Dependency audits

Local audit tasks use `licence_audit` v0.11.1, pinned in `.mise.toml`.
Install it with `mise install github:tylerbutler/licence_audit`. mise selects
the self-contained platform archive; the repo's Erlang version is unchanged.

```bash
just audit-licences          # Report licences and preview the existing policy
just audit-vulns             # Report known vulnerabilities from OSV
just audit-check             # Enforce licences and the vulnerability threshold
just audit-check beryl_mist  # Limit the task to one package
```

These tasks default to `beryl`, `beryl_mist`, and `beryl_ewe`. Each command runs
in the package directory and reads its locked manifest. Licence reports and
enforcement use its existing `[tools.licence_audit]` policy.
Examples are not included by default. To report on an example, pass its
package name, such as `just audit-licences cursor`.
Examples need an approved licence policy before licence enforcement is useful.

The report tasks do not fail on findings; `audit-check` uses `check --vulns`
and propagates failures. The existing policies allow Apache-2.0, ISC, and MIT.
The default vulnerability threshold is `high`; unknown severity does not
block. No audit task is part of CI or `just ci`.

Licence reports cover locked Hex dependencies, not Git or local path sources.
Vulnerability reports cover Hex and GitHub dependencies; other sources are
skipped. This does not audit npm dependencies. OSV requires network access;
an unavailable service means the audit is incomplete.

Use `mise exec -- licence_audit --version` to see the installed version.
If Hex metadata requests time out, the licence audit is incomplete. Retry the
task without changing the policy; report-task success alone does not mean
that all metadata was fetched.

### Before Merging to Main

```bash
# Run extended checks
just main
```

## Code Style

### Formatting

This project uses Gleam's built-in formatter. Format your code before committing:

```bash
just format
```

### Error Handling

Always use Result types for fallible operations:

```gleam
// Good
pub fn parse(input: String) -> Result(Value, ParseError)

// Avoid: functions that can fail but don't return Result
pub fn parse(input: String) -> Value  // Don't do this
```

### Pattern Matching

Gleam enforces exhaustive pattern matching. Handle all cases:

```gleam
case result {
  Ok(value) -> handle_success(value)
  Error(ParseError(msg)) -> handle_parse_error(msg)
  Error(ValidationError(field)) -> handle_validation_error(field)
}
```

### Documentation

The website installation example selects the highest published `vMAJOR.MINOR`
tag with `git ls-remote` during rendering. Website builds need Git and network
access to GitHub; they fail if the lookup fails or no minor tag exists. Local
tags and shallow clone depth do not affect the selected ref. Rebuild the
website after publishing a new minor tag to update the example.

Document all public functions with `///` comments:

```gleam
/// Parses the input string into a Value.
///
/// ## Examples
///
/// ```gleam
/// parse("hello")
/// // -> Ok(Value("hello"))
/// ```
///
/// ## Errors
///
/// Returns `ParseError` if the input is malformed.
pub fn parse(input: String) -> Result(Value, ParseError)
```

## Testing

### Running Tests

```bash
# Run all tests
just test

# Run the core package sequentially
cd packages/beryl && gleam test

# Run real-node PubSub and presence recovery from the repository root
just test-distributed

# Run with verbose output
gleam test -- --verbose
```

The root `just test` command runs the parallel-safe `beryl` tests with
unitest's automatic worker count, capped at four BEAM schedulers to avoid
nested oversubscription, then runs its `serial` tag in a separate sequential
lane. It then runs the EUnit distributed matrix on real Erlang peer nodes.
Package-scoped commands keep the same behavior: `just test beryl` runs all
three core lanes, while `just test beryl_mist` does not run core tests.

`gleam test` uses unitest, which discovers `.gleam` tests only. It does not
run `beryl_presence_distributed_test.erl`. Use `just test-distributed` for that
suite, or `just test beryl` for complete core coverage. The source CI job runs
the three lanes on both Erlang 27 and 28.

The distributed harness controls peers through standard I/O so test queries
cannot heal a distribution partition. It waits for `pg` membership, snapshot
rounds, and exact entry identities; broadcast barriers make sender-exclusion
and scope-isolation checks deterministic. Each test stops its peers in cleanup
blocks, including on failure. The retirement case waits for the production
60-second retention period, so the suite takes at least one minute.

### Tutorial browser demos

Run `just site-demos-test` to build the documentation site and test its three
tutorial simulations with Playwright. After a site build, run
`pnpm --dir website test:demos` to repeat only the browser tests. To select
one demo, append its test file, such as `e2e/socket-loop.spec.ts`.

The tests start a local preview on port 4329. Stop any other service on that
port before running them. Install Chromium with
`pnpm --dir website exec playwright install chromium` if Playwright reports
a missing browser. Test reports and traces stay in ignored website directories.

### Writing Tests

Tests use unitest as the runner and `gleeunit/should` for assertions:

```gleam
import gleeunit/should
import beryl

pub fn my_feature_test() {
  beryl.some_function("input")
  |> should.equal(expected_output)
}

pub fn error_case_test() {
  beryl.parse("invalid")
  |> should.be_error()
}
```

Tests that observe or change process-wide state must use the `serial` tag:

```gleam
import unitest

pub fn captures_global_telemetry_test() {
  use <- unitest.tag("serial")
  // Test code
}
```

This includes tests that attach `:telemetry` handlers, install the Palabres
capture handler, change Palabres's global logging level, or deliberately
exercise VM-sensitive restart exhaustion, PubSub scope recovery, or tightly
controlled actor restart and delayed-ack scheduling. Do not tag tests that can
use unique subjects, scopes, socket IDs, or exact mailbox selectors for
isolation.

Filter tests by name, file, line, or tag by passing unitest arguments after
`--`:

```bash
gleam test -- --test my_module.my_feature_test
gleam test -- test/my_module_test.gleam:12
gleam test -- --tag slow
```

## Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Code style (formatting) |
| `refactor` | Code refactoring |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `build` | Build system changes |
| `ci` | CI/CD changes |
| `chore` | Maintenance tasks |

### Examples

```bash
feat(channel): add support for binary messages
fix(presence): handle concurrent leave/join correctly
docs: update installation instructions
test: add edge case tests for topic matching
```

## Release Process

Releases are driven by trellis changelog fragments (TOML files in
`.changes/unreleased/` with `project`, `kind`, and `body` fields).

### When a fragment is required

A fragment applies only to what a released package ships — its `src/`,
`gleam.toml`, or `manifest.toml`. It describes what a consumer of the
published package receives. Add a fragment when you change a package's public
API, its observable behavior, its dependency requirements, or its `///` doc
comments (these ship in the API reference).

Do not add a fragment for anything a package does not ship. The `website/`,
`docs/`, and `examples/` directories and the dev tooling reach no consumer, so
a fragment for them bumps a version that nobody sees. Test files, internal
refactors, and formatting that keep the consumer-visible behavior the same
also need no fragment.

### Steps

1. Make changes following the commit message convention
2. Add a changelog entry: `just change <package> <kind> "<body>"`
   (e.g. `just change beryl Fixed "handle concurrent leave/join"`); PR CI
   enforces this via `trellis changelog check`
3. Push to a feature branch and create a PR
4. After merge, the release workflow runs `trellis release pr`, which batches
   fragments into a release PR (branch `release/pending`) bumping versions
   and regenerating each package's CHANGELOG.md
5. Merging the release PR creates per-package tags (`beryl-v1.2.3`) and GitHub
   releases. Hex.pm publishing is temporarily disabled — `trellis publish` is
   not run; see the header comment in `.github/workflows/publish.yml` for how
   to resume it

Useful commands: `just version-plan` previews the next versions;
`just doctor` validates workspace invariants.

### 1.0 release checklist

One-time steps to perform in the same PR that tags `v1.0.0`:

- Remove (or rewrite) the "beryl is not yet 1.0 / API is unstable" callout.
  The wording is identical everywhere it appears, so one find-and-replace
  covers all of them:
  - `README.md`, `packages/beryl/README.md`, `packages/beryl_mist/README.md`,
    `packages/beryl_ewe/README.md`
  - `website/src/content/docs/`: `introduction.md`, `installation.md`,
    `quick-start.mdx`, `examples.mdx`, `reference/index.md` (the last one
    keeps its trailing "See the Stability policy" pointer)
- Confirm the documented Gleam version requirement in `README.md` and
  `website/src/content/docs/installation.md`. Note that the documented
  requirement (1.18+) is deliberately higher than the `gleam` constraint in each
  package's `gleam.toml` (1.13+): 1.18 is what *consumers* need for the
  `path` field on git dependencies, not what beryl needs to compile. If beryl is
  published to Hex, that consumer-side requirement goes away and the docs should
  drop back to the manifest constraint.
- Verify the publish tarball with `gleam export hex-tarball` before tagging.

## Troubleshooting

### Build Errors

```bash
# Clean build artifacts and rebuild
just clean
just deps
just build
```

### Test Failures

```bash
# Run a specific test
gleam test -- --filter "test_name"

# Run with more output
gleam test -- --verbose
```

### Dependency Issues

```bash
# Update dependencies
gleam deps update

# Check for outdated dependencies
gleam deps list
```

## Getting Help

- Check the [Gleam documentation](https://gleam.run/documentation/)
- Join the [Gleam Discord](https://discord.gg/Fm8Pwmy)
- Open an issue on GitHub
