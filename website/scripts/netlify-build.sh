#!/usr/bin/env bash
# Shared hosting build: Cloudflare and Netlify both need the Gleam compiler.
# The package's `build:site` command calls this script. `build:interactive` compiles the
# Lustre client to JavaScript with `gleam build --target javascript`, which
# needs only the Gleam binary (no Erlang), and Astro/Vite bundles the result.
set -euo pipefail

GLEAM_VERSION="${GLEAM_VERSION:-1.18.1}"

if ! command -v gleam >/dev/null 2>&1; then
  echo "Installing gleam v${GLEAM_VERSION}..."
  install_dir="${PWD}/interactive/build/toolchain"
  mkdir -p "${install_dir}"
  curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C "${install_dir}"
  export PATH="${install_dir}:${PATH}"
fi

gleam --version
pnpm run generate:og
pnpm run build:interactive
pnpm exec astro build
