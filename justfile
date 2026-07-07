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

# Run the glinter linter
lint:
    gleam run -m glinter

# === DOCUMENTATION ===

# Build Gleam API documentation (HTML + docs metadata)
gleam-docs:
    gleam docs build

# Build documentation: Gleam docs + regenerated website reference pages
docs: gleam-docs
    pnpm -C website generate:reference

# Render the architecture deck to HTML
deck:
    npx -y -p @marp-team/marp-core -p @marp-team/marp-cli marp docs/architecture-deck.md --engine docs/marp.engine.mjs --html -o docs/architecture-deck.html

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

# Install website dependencies
site-deps:
    pnpm -C website install

# Regenerate website reference docs (delegates to `docs`, which regenerates them)
site-reference: docs

# Test the website reference docs generator
site-reference-test:
    pnpm -C website test:reference

# Build website
site-build: site-reference
    pnpm -C website build:site

# Check website (Astro check)
site-check: site-reference
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

# Build the cursors example Docker image (must run from repo root for path-based beryl dep)
examples-cursors-docker tag="beryl-cursors":
    docker build -f examples/cursors/Dockerfile -t {{tag}} .

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
