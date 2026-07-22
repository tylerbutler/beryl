# beryl workspace tasks — gleam packages are managed by trellis
# (https://trellis.tylerbutler.com); see [tools.trellis] in gleam.toml.

# === ALIASES ===
alias b := build
alias t := test
alias f := format
alias c := check
alias d := docs

default:
    @just --list

# === DEPENDENCIES ===

# Download all dependencies (gleam packages + pnpm workspaces)
deps: deps-gleam
    pnpm -C examples install
    pnpm -C website install

# Download gleam dependencies for every workspace member
deps-gleam:
    trellis run deps

# === BUILD ===

# Build all packages (Erlang target)
build *ARGS:
    trellis run build {{ARGS}}

# Build with warnings as errors
build-strict:
    trellis run build --strict

# === TESTING ===

# Run all tests (optionally scope to packages: `just test beryl_mist`)
test *ARGS:
    trellis run test {{ARGS}}

# === CODE QUALITY ===

# Format source code in every package
format:
    trellis run format

# Check formatting without changes
format-check:
    trellis run format --check

# Type check without building
check:
    trellis run check

# Run the glinter linter (packages only; examples are excluded)
lint:
    trellis run lint

# Check workspace invariants (members, graph, versions, fragments)
doctor:
    trellis doctor

# === DOCUMENTATION ===

# Build Gleam API documentation (HTML + docs metadata) for both packages
gleam-docs:
    trellis run docs

# Build documentation: Gleam docs + regenerated website reference pages
docs: gleam-docs
    pnpm -C website generate:reference

# Render the architecture deck to HTML
deck:
    npx -y -p @marp-team/marp-core -p @marp-team/marp-cli marp docs/architecture-deck.md --engine docs/marp.engine.mjs --html -o docs/architecture-deck.html

# === CHANGELOG / RELEASE ===

# Create a new changelog entry, e.g. `just change beryl Fixed "handle X"`
change PACKAGE KIND BODY:
    trellis changelog new --package {{PACKAGE}} --kind {{KIND}} --body "{{BODY}}"

# Check fragments against changes since main
changelog-check:
    trellis changelog check --base origin/main

# Preview the next versions computed from unreleased fragments
version-plan:
    trellis version plan

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
examples-build: examples-client-build
    trellis run build chatrooms collab_docs cursors example_helpers showcase collab_docs_client

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
    pnpm -C examples/showcase test

# Build the cursors example Docker image (must run from repo root for path-based beryl dep)
examples-cursors-docker tag="beryl-cursors":
    docker build -f examples/cursors/Dockerfile -t {{tag}} .

# === MAINTENANCE ===

# Remove build artifacts
clean:
    trellis run clean
    pnpm -C website clean

# === CI ===

# Run all CI checks (format, check, test, build, examples)
ci: format-check check docs test build-strict examples-test

# Alias for PR checks
alias pr := ci

# Run extended checks for main branch
main: ci docs
