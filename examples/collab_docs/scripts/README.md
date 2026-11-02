# Document client bundling

## Overview

This script packages the JavaScript-targeted Gleam client for the editor page.

## Interface

- `bundle-client.mjs:builtEntrypoint` selects the built `collab_docs_client`
  entry point. The script runs through `package.json:scripts.build:client`.

## Invariants

- `bundle-client.mjs:GLEAM_BUILD_PROFILE` and `GLEAM_ENV` select the requested
  profile. Without an override, the script checks dev/prod build candidates.
- `bundle-client.mjs:builtEntrypoint` errors when no built entry point exists.

## Side effects

- `bundle-client.mjs` creates the output directory and invokes esbuild to
  write `priv/static/collab_docs_client.mjs` as a browser ESM bundle.

## Verification

From the repository root: `pnpm -C examples/collab_docs build:client`.
This builds the client before invoking the bundler.
