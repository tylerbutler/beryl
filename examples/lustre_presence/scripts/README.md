# Dashboard client bundling

## Overview

This script bundles the Gleam/Lustre client and its Phoenix dependency.

## Interface

- `bundle-client.mjs:builtEntrypoint` selects the built
  `lustre_presence_client` entry point.
- `package.json:scripts.build:client` builds Gleam before running the script.

## Invariants

- `bundle-client.mjs:GLEAM_BUILD_PROFILE` and `GLEAM_ENV` can select a profile.
  Without an override, `builtEntrypoint` selects the newest dev/prod artifact.

## Side effects

- `bundle-client.mjs` invokes esbuild and writes a minified browser ESM bundle
  to `priv/static/lustre_presence_client.js`.

## Verification

From the repository root: `pnpm -C examples/lustre_presence build:client`.
