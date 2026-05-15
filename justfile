# Gleam Project Tasks

# === ALIASES ===
alias b := build
alias t := test
alias f := format
alias c := check
alias d := docs
alias cl := change

default:
    @just --list

# === DEPENDENCIES ===

# Download project dependencies (including examples)
deps:
    gleam deps download
    cd examples/example_helpers && gleam deps download
    cd examples/cursors && gleam deps download
    cd examples/chatrooms && gleam deps download
    cd examples/collab_docs && gleam deps download
    cd examples/collab_docs/client && gleam deps download
    pnpm -C examples install

# === BUILD ===

# Build project (Erlang target)
build:
    gleam build

# Build with warnings as errors
build-strict:
    gleam build --warnings-as-errors

# === TESTING ===

# Run all tests
test:
    gleam test

# === CODE QUALITY ===

# Format source code
format:
    gleam format src test

# Check formatting without changes
format-check:
    gleam format --check src test

# Type check without building
check:
    gleam check

# === DOCUMENTATION ===

# Build documentation
docs:
    gleam docs build

# === CHANGELOG ===

# Create a new changelog entry
change:
    changie new

# Preview unreleased changelog
changelog-preview:
    changie batch auto --dry-run

# Generate CHANGELOG.md
changelog:
    changie merge

# === WEBSITE ===

# Start website dev server
site-dev:
    pnpm -C website dev

# Build website
site-build:
    pnpm -C website build:site

# Install website dependencies
site-deps:
    pnpm -C website install

# Check website (Astro check)
site-check:
    pnpm -C website check:astro

# Clean website build artifacts
site-clean:
    pnpm -C website clean

# === EXAMPLES ===

# List all examples
examples-list:
    @ls examples/

# Build all examples
examples-build: examples-clean examples-client-build
    cd examples/cursors && gleam build
    cd examples/chatrooms && gleam build
    cd examples/collab_docs && gleam build

# Clean example build artifacts
examples-clean:
    rm -rf examples/cursors/_build
    rm -rf examples/chatrooms/_build
    rm -rf examples/collab_docs/_build
    rm -rf examples/collab_docs/client/_build

# Build JavaScript clients used by examples
examples-client-build:
    pnpm -C examples/collab_docs build:client

# Install example test dependencies (Playwright)
examples-deps:
    pnpm -C examples install

# Run example Playwright tests
examples-test: examples-build
    pnpm -C examples/cursors test
    pnpm -C examples/chatrooms test
    pnpm -C examples/collab_docs test

# === MAINTENANCE ===

# Remove build artifacts
clean: examples-clean
    rm -rf _build
    rm -rf build

# === CI ===

# Run all CI checks (format, check, test, build, examples)
ci: format-check check test build-strict examples-test

# Alias for PR checks
alias pr := ci

# Run extended checks for main branch
main: ci docs

# =============================================================================
# MULTI-TARGET SUPPORT (Uncomment if targeting JavaScript)
# =============================================================================

# # Build for JavaScript target
# build-js:
#     gleam build --target javascript

# # Build all targets
# build-all: build build-js

# # Build JavaScript with warnings as errors
# build-strict-js:
#     gleam build --target javascript --warnings-as-errors

# # Build all targets strictly
# build-strict-all: build-strict build-strict-js

# # Test on Erlang target
# test-erlang:
#     gleam test

# # Test on JavaScript target
# test-js:
#     gleam test --target javascript

# # Test on all targets
# test-all: test-erlang test-js

# =============================================================================
# JAVASCRIPT INTEGRATION TESTS (Uncomment if needed)
# =============================================================================

# # Run integration tests with Node.js
# test-integration-node: build-js
#     node --test test/integration/test_runner.mjs

# # Run integration tests with Deno
# test-integration-deno: build-js
#     deno test --allow-read --allow-env test/integration/test_runner.mjs

# # Run integration tests with Bun
# test-integration-bun: build-js
#     bun test test/integration/test_runner.mjs

# =============================================================================
# COVERAGE (Uncomment if needed)
# =============================================================================

# # Run tests with coverage (requires setup - see README)
# coverage:
#     @echo "Coverage requires additional setup. See README.md"
