#!/usr/bin/env bash
# Netlify build script: installs the Gleam compiler (not in Netlify's build
# image), then runs the normal site build. `build:interactive` compiles the
# Lustre client to JavaScript with `gleam build --target javascript`, which
# needs only the Gleam binary (no Erlang), and Astro/Vite bundles the result.
set -euo pipefail

GLEAM_VERSION="${GLEAM_VERSION:-1.18.1}"

if ! command -v gleam >/dev/null 2>&1; then
  echo "Installing gleam v${GLEAM_VERSION}..."
  install_dir="${HOME}/.gleam-bin"
  mkdir -p "${install_dir}"
  curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C "${install_dir}"
  export PATH="${install_dir}:${PATH}"
fi

gleam --version
pnpm build:site
