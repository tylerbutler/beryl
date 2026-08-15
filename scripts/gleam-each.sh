#!/usr/bin/env bash
# Runs a gleam verb (check/build/test/docs) across workspace packages, one
# package at a time via a plain sequential shell-out to `gleam` — no trellis
# task scheduler involved.
#
# Why this exists: intermittently, a package with a path dependency (e.g.
# `beryl_ewe` or `beryl_mist` depending on `beryl`) ends up with a corrupted
# or incomplete cached copy of that path dependency's compiled interface in
# its own build/ directory, causing spurious "Unknown module"/"Unknown type"
# errors for modules that import fine everywhere else. This has been
# confirmed to be independent of concurrency: it reproduces under a fully
# serial, one-subprocess-at-a-time loop (this script, run with trellis's
# scheduler bypassed entirely), and moves between different packages across
# runs. It looks like genuine Gleam-compiler nondeterminism, not a code
# defect or a trellis bug — see split/lane-f-load-suite's CI investigation.
#
# The corruption is confined to the affected package's own build/ dir: once
# a package fails this way, re-running the same command again without
# cleaning fails identically every time, but a `gleam clean` (removing
# build/) before retrying reliably fixes it. So on failure this script
# cleans and retries the failing package a few times before giving up.
#
# Usage: gleam-each.sh <verb> [package...]
#   verb: check | build | build-strict | test | docs
#   package...: explicit package names (topological order not required —
#     each package's own gleam invocation resolves its own path deps).
#     Defaults to every workspace package (minus the verb's excludes) when
#     omitted.
set -euo pipefail

max_attempts=5

verb=${1:-}
if [[ -z "$verb" ]]; then
  echo "usage: gleam-each.sh <check|build|build-strict|test|docs> [package...]" >&2
  exit 1
fi
shift

case "$verb" in
  check) gleam_args=(check) ;;
  build) gleam_args=(build) ;;
  build-strict) gleam_args=(build --warnings-as-errors) ;;
  test) gleam_args=(test) ;;
  docs) gleam_args=(docs build) ;;
  *)
    echo "gleam-each: unknown verb \`$verb\`" >&2
    exit 1
    ;;
esac

# Mirrors [tools.trellis.exclude] in the root gleam.toml, which has no
# per-task exclusion for check/build/build-strict, "examples/**" for docs,
# and this explicit list (packages with no test/ dir) for test.
is_excluded() {
  local path=$1
  case "$verb" in
    docs)
      [[ "$path" == examples/* ]]
      ;;
    test)
      case "$path" in
        examples/chatrooms | examples/cursors | examples/example_helpers | examples/showcase) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

all_packages_json=$(trellis list --json)

if [[ $# -gt 0 ]]; then
  packages=("$@")
else
  packages=()
  while IFS= read -r name; do
    packages+=("$name")
  done < <(echo "$all_packages_json" | jq -r '.packages[].name')
fi

fail=0
for name in "${packages[@]}"; do
  path=$(echo "$all_packages_json" | jq -r --arg name "$name" '.packages[] | select(.name == $name) | .path')
  if [[ -z "$path" ]]; then
    echo "gleam-each: unknown package \`$name\`" >&2
    exit 1
  fi

  if is_excluded "$path"; then
    continue
  fi

  echo "=== $name (gleam ${gleam_args[*]}) ==="
  attempt=1
  ok=0
  while [[ $attempt -le $max_attempts ]]; do
    log=$(mktemp)
    if (cd "$path" && gleam "${gleam_args[@]}") 2>&1 | tee "$log"; then
      ok=1
      rm -f "$log"
      break
    fi
    echo "=== $name FAILED (attempt $attempt/$max_attempts) ==="
    if [[ $attempt -lt $max_attempts ]]; then
      if grep -qi "rate limit" "$log"; then
        # Hex rate-limiting needs time, not a clean — wiping build/ here
        # would force re-resolution and make the next attempt trip the
        # same limit again.
        backoff=$((attempt * 10))
        echo "=== $name: Hex API rate limit hit, waiting ${backoff}s before retrying ==="
        sleep "$backoff"
      else
        # The corrupted state has been observed to live in a path
        # dependency's own build/ dir (e.g. beryl's, when beryl_ewe or
        # beryl_mist depends on it), not necessarily $name's — cleaning
        # only $name's build/ was confirmed insufficient. Clean every
        # package processed so far this run and retry.
        echo "=== $name: cleaning build/ for all packages run so far and retrying ==="
        for cleaned in "${packages[@]}"; do
          cleaned_path=$(echo "$all_packages_json" | jq -r --arg name "$cleaned" '.packages[] | select(.name == $name) | .path')
          [[ -n "$cleaned_path" ]] && rm -rf "$cleaned_path/build"
          [[ "$cleaned" == "$name" ]] && break
        done
      fi
    fi
    rm -f "$log"
    attempt=$((attempt + 1))
  done
  if [[ $ok -ne 1 ]]; then
    echo "=== $name FAILED after $max_attempts attempts ==="
    fail=1
    break
  fi
done

exit $fail
