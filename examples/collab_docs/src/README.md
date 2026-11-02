# Document server source

## Overview

The entry point assembles the authenticated document channel and store.

## Interface

- `collab_document.gleam:main` starts the application.
- `collab_docs_ffi.erl:timestamp_ms` and `random_id` provide Erlang primitives.
- [Server modules](./collab_document/README.md) own authentication, routing,
  channel callbacks, and storage.

## Invariants

`collab_document.gleam:main` creates a fresh authentication secret on startup.
The child channel requires a tenant-signed token and bounds state updates.

## Side effects

- `collab_document.gleam:main` initializes assets, the document-store actor,
  and supervision, starts Mist on port 8002, and sleeps indefinitely.
- `collab_docs_ffi.erl:timestamp_ms` reads time; `random_id` allocates a
  positive monotonic unique integer.

## Verification

From the repository root: `cd examples/collab_docs && gleam build`.
Browser verification uses `pnpm -C examples/collab_docs test`.
