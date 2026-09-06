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

## Development Workflow

### Daily Development

```bash
# Check your code compiles
just check

# Run tests
just test

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

# Run with verbose output
gleam test -- --verbose
```

### Writing Tests

Tests use the `gleeunit` framework:

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
