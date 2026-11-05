#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

paths=(
  packages/*/build/packages
  examples/*/build/packages
  examples/*/client/build/packages
  build/snippet-check/manifest.toml
  build/snippet-check/build/packages
)

# Tar preserves executable bits and local dependency symlinks in artifacts.
tar -czf "$1/gleam-dependencies.tar.gz" "${paths[@]}"
tar -czf "$1/gleam-hex-cache.tar.gz" \
  -C "$HOME/.cache/gleam/hex/hexpm" packages
