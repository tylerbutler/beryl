# Showcase HTTP routing

## Overview

The local router delegates cursor and chat pages to sibling example packages.
The child channel handlers own per-topic application behavior.

## Interface

- `router.gleam:Context` and `handle_request` expose HTTP routing.
- [Channel handlers](./channel/README.md) supply cursor, document, and room handlers.

## Invariants

- `router.gleam:handle_request` serves `/`, `/healthz`, `/cursors`, and `/chat`.
  The `/docs` branch is commented out; unmatched paths return not-found.
- `/healthz` returns plain-text `ok`.

## Side effects

`router.gleam:handle_request` returns HTTP responses and delegates asset serving.
The child channel handlers change presence/document state and broadcast events.

## Verification

From the repository root: `cd examples/showcase && gleam build`.
Browser verification uses `pnpm -C examples/showcase test` (port 8010 in Playwright).
