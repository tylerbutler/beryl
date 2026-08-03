# Development Guide

This document provides detailed instructions for developing and contributing to this project.

## Prerequisites

Ensure you have the following installed:

| Tool | Version | Purpose |
|------|---------|---------|
| Erlang/OTP | 27.2.1+ | BEAM runtime |
| Gleam | 1.16.0+ | Compiler and tooling |
| just | 1.50.0+ | Task runner |
| [trellis](https://trellis.tylerbutler.com) | 0.3.0+ | Gleam workspace manager (tasks, versions, publishing) |

**Recommended:** Use [mise](https://mise.jdx.dev/) or [asdf](https://asdf-vm.com/) with the provided `.tool-versions` file. trellis is pinned in `.mise.toml` (mise's GitHub backend); it can also be installed via its shell installer or Homebrew.

This repository is a trellis-managed workspace: the publishable packages live
in `packages/beryl`, `packages/beryl_channels`, and `packages/beryl_mist`
(`packages/beryl_ewe` is built, tested and linted but excluded from release
until it is ready), runnable examples in `examples/`, and the root
`gleam.toml` holds only the `[tools.trellis]` configuration. `just` recipes
fan out across the workspace through `trellis run`.

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
5. Merging the release PR publishes every untagged package to Hex in
   dependency order and creates per-package tags (`beryl-v1.2.3`) and GitHub
   releases

Useful commands: `just version-plan` previews the next versions;
`just doctor` validates workspace invariants.

### 1.0 release checklist

One-time steps to perform in the same PR that tags `v1.0.0`:

- Remove (or rewrite) the "beryl is not yet 1.0 / API is unstable" callout at
  the top of `README.md`.
- Confirm the documented Gleam version requirement in `README.md` and
  `website/src/content/docs/installation.md` still matches `gleam.toml`.
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
