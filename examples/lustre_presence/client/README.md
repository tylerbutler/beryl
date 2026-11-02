# Lustre client package

## Overview

This nested JavaScript-targeted Gleam package owns the dashboard browser app.
The parent npm package supplies Phoenix and esbuild.

## Subdirectories and boundaries

- [Application source](./src/README.md): Lustre model/effects and local
  presence/channel adapters.

## Interface

`gleam.toml:name` identifies `lustre_presence_client`; `target` selects JavaScript.
`src/lustre_presence_client.gleam:main` starts the app.

## Invariants

`src/lustre_presence_client.gleam:main` connects to `/socket` and joins
`page:dashboard`. The server authenticates through the browser session cookie.

## Side effects

The application starts Lustre and connects the channel through browser effects.
The parent bundler writes the static bundle.

## Verification

From the repository root: `cd examples/lustre_presence/client && gleam build`.
The root `gleam.toml` excludes this client from workspace tests.
`pnpm -C examples/lustre_presence build:client` checks the browser bundle.
