# Cursor server source

## Overview

The executable starts the raw-dispatch cursor app and HTTP/WebSocket server.

## Interface

- `cursor.gleam:main` is the executable entry point.
- [Cursor modules](./cursor/README.md) own per-topic behavior and HTTP routing.

## Invariants

- `cursor.gleam:main` defaults to port 8000 and interface `localhost`;
  `PORT` and `BIND_ADDRESS` override those values.
- The child app admits `cursor:*` topics and validates reaction coordinates.

## Side effects

`cursor.gleam:main` starts session presence, supervision, and Mist, then
sleeps indefinitely.

## Verification

From the repository root: `cd examples/cursors && gleam build`.
The root workspace test task excludes this package; use
`pnpm -C examples/cursors test` for browser verification.
