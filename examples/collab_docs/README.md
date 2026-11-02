# Collaborative CRDT Docs

## Overview

This example shows a collaborative document editor built with beryl app-side
dispatch and client-side CRDT state.

## What it demonstrates

| Feature | How it is used |
|---|---|
| Tenant/document topic validation | The handler registers `document:*`, then splits the captured suffix into exactly two components: tenant and document. |
| Client-side CRDT merge | The browser keeps document blocks with the `lattice_core`, `lattice_maps`, and `lattice_registers` packages as an `ORMap(MVRegister(String))`. |
| Unordered realtime transport | beryl carries serialized document state updates between clients without requiring total message ordering. |
| Late joiner cache | The server caches merged document state and returns it in the join reply for newly connected clients. |
| Conflict UI | Concurrent edits to the same block render explicit conflict cards with each version. |

## Run

From the repository root, install dependencies once and then start the example:

```bash
just deps
cd examples/collab_docs && gleam run
```

Open <http://localhost:8002> in multiple browser tabs.

## Test

From the repository root:

```bash
pnpm -C examples/collab_docs test
```

If you only need the browser test dependencies, run
`pnpm -C examples install` from the repository root first.

## Subdirectories and boundaries

- [Server source](./src/README.md): startup, signed tenant tokens, channel,
  document-store actor, and router.
- [Client package](./client/README.md): pure JavaScript-targeted CRDT document API.
- [Browser assets](./priv/README.md): editor UI and generated bundle.
- [Bundler](./scripts/README.md): turns the built client into the browser module.

## Interface

`src/collab_document.gleam:main` starts the Erlang server package
`collab_document`. `src/collab_document/app.gleam:handler` exposes the
document channel. The nested `client/gleam.toml` declares the separate
`collab_docs_client` package; lattice dependencies own its CRDT algorithms.

## Invariants

- `src/collab_document/app.gleam:authorize_join` requires tenant/document
  parameters and a token verified for that tenant.
- `src/collab_document/app.gleam:handler` bounds serialized state updates
  to 65,536 bytes.
- `src/collab_document/document_store.gleam:merge_state` enqueues asynchronous
  merges; reads distinguish missing state and timeout.
- `scripts/bundle-client.mjs` owns the generated static client bundle.

## Side effects

`src/collab_document.gleam:main` creates a fresh secret, starts the store and
supervision, and listens on port 8002. Channel callbacks merge/broadcast state.
The browser changes the DOM and sends document updates; bundling writes an asset.

## Verification

From the repository root: `cd examples/collab_docs && gleam build`;
`pnpm -C examples/collab_docs build:client` checks the browser build.
The `pnpm test` command above runs Playwright. The server and nested client
are not in the root workspace test exclusions.
