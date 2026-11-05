# Lustre dashboard application

## Overview

The browser app maintains connection and presence state and renders the
online-user dashboard.

## Interface

- `lustre_presence_client.gleam:Connection`, `Model`, `Message`, `main`,
  `initial_model`, and `update` expose the application model and entry point.
- [Client adapters](./lustre_presence_client/README.md) own channel lifecycle,
  Phoenix FFI, and roster decoding.

## Invariants

- The application connects to `/socket` and joins `page:dashboard`
  (`lustre_presence_client.gleam:main`).
- `lustre_presence_client.gleam:update` accepts decoded presence updates and
  records errors for display.

## Side effects

`lustre_presence_client.gleam:main` starts Lustre. Its effects connect/close
the channel and render browser UI.

## Verification

From the repository root: `cd examples/lustre_presence/client && gleam build`.
Use `pnpm -C examples/lustre_presence build:client` to verify browser bundling.
