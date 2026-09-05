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
    trellis run deps --serial

# === BUILD ===

# Build all packages (Erlang target)
build *ARGS:
    trellis run build {{ ARGS }}

# Build with warnings as errors
build-strict:
    trellis run build --strict

# === TESTING ===

# Run all tests (optionally scope to packages: `just test beryl_mist`)
test *ARGS:
    trellis run test {{ ARGS }}

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

# Build Gleam API documentation for publishable workspace packages
gleam-docs:
    trellis run docs

# Build documentation: Gleam docs + regenerated website reference pages
docs: gleam-docs
    cd website && pnpm run generate:reference

# Render the architecture deck to HTML
deck:
    npx -y -p @marp-team/marp-core -p @marp-team/marp-cli marp docs/architecture-deck.md --engine docs/marp.engine.mjs --html -o docs/architecture-deck.html

# === CHANGELOG / RELEASE ===

# Create a new changelog entry, e.g. `just change beryl Fixed "handle X"`
change PACKAGE KIND BODY:
    trellis changelog new --package {{ PACKAGE }} --kind {{ KIND }} --body "{{ BODY }}"

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

# Type-check every Gleam snippet in the docs against the real packages
site-snippets: gleam-docs
    pnpm -C website check:snippets

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
    trellis run build chatroom collab_document cursor example_helper showcase load_test live_poll collab_docs_client

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
    docker build -f examples/cursors/Dockerfile -t {{ tag }} .

# Run the headless benchmark target with Mist or Ewe.
load-server-mist:
    cd examples/load_test && gleam run -m load_test_mist

load-server-ewe:
    cd examples/load_test && gleam run -m load_test_ewe

# Build the benchmark image from the repository root. Select SERVER=mist|ewe.
load-server-docker server="mist" tag="beryl-load-test":
    docker build -f examples/load_test/Dockerfile --build-arg SERVER={{ server }} -t {{ tag }} .

# === MAINTENANCE ===

# Remove build artifacts
clean:
    trellis run clean
    pnpm -C website clean

# === CI ===

# Run all CI checks (format, check, test, build, examples)
ci: format-check check docs site-snippets test build-strict examples-test

# Alias for PR checks
alias pr := ci

# Run extended checks for main branch
main: ci docs

# === LOAD TESTING ===

# Parse every local k6 JavaScript file without contacting a target
load-syntax:
    npm --prefix load/k6 run syntax

# Run pure client, configuration, profile, and lifecycle checks
load-helpers:
    npm --prefix load/k6 run check

# Validate local helpers and inspect the selected script with official k6
load-check profile="protocol-smoke":
    just load-syntax
    just load-helpers
    docker run --rm -v "$PWD:/work" -w /work grafana/k6:2.1.0 inspect -e PROFILE="{{ profile }}" -e TARGET_URL="ws://example.invalid/socket" -e HTTP_TARGET_URL="http://example.invalid/health" load/k6/run.js

# Run a profile; target may be one URL or comma-separated cluster URLs
load-run profile target transport="unknown":
    mkdir -p load/results
    docker run --rm --network host --user "$(id -u):$(id -g)" -v "$PWD:/work" -w /work -e PROFILE="{{ profile }}" -e TARGET_URLS="{{ target }}" -e TRANSPORT="{{ transport }}" -e VUS -e RATE -e DURATION -e PREALLOCATED_VUS -e MAX_VUS -e WS_PATH -e TOKEN -e TOKEN_PARAM -e TOPICS -e CONNECT_TIMEOUT_MS -e REPLY_TIMEOUT_MS -e LEAVE_TIMEOUT_MS -e HEARTBEAT_INTERVAL_MS -e HEARTBEAT_TIMEOUT_MS -e EXPIRED_REF_LIMIT -e TOPIC -e EVENT -e HTTP_TARGET_URL -e SESSION_DURATION_MS -e OPERATION_INTERVAL_MS -e DELIVERY_TIMEOUT_MS -e BROADCAST_TOPIC -e BROADCAST_EVENT -e BROADCAST_DELIVERY_EVENT -e BROADCAST_ACK_EVENT -e BROADCAST_GROUP_SIZE -e BROADCAST_EXPECTED_RECIPIENTS -e BROADCAST_WARMUP_MS -e PRESENCE_TRACK_EVENT -e PRESENCE_UNTRACK_EVENT -e PRESENCE_DELIVERY_EVENT -e GUARDRAIL_TOPIC -e GIT_SHA -e RUNTIME -e HARDWARE -e SOURCE_IP -e CLUSTER -e LOAD_GENERATOR -e LOAD_GENERATOR_INDEX -e LOAD_GENERATOR_COUNT -e EXECUTION_SEGMENT -e EXECUTION_SEGMENT_SEQUENCE -e TARGET_LABEL -e RUN_ID -e SUMMARY_PATH grafana/k6:2.1.0 run load/k6/run.js
