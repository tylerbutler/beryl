# Document server modules

## Overview

These modules own channel authorization, demo tenant tokens, actor-backed
document storage, and HTTP routing. Lattice packages supply CRDT operations.

## Interface

- `app.gleam:Model`, `Context`, `build_document_key`, `handler`, and
  `authorize_join` expose channel setup and authorization.
- `auth.gleam:new_secret`, `sign_tenant`, and `verify_tenant` expose token helpers.
- `document_store.gleam:Store`, `GetError`, `start`, `get_state`, and
  `merge_state` expose the opaque store handle and operations.
- `router.gleam:Context` and `handle_request` expose HTTP routing.

## Invariants

- `app.gleam:authorize_join` requires tenant/document topic parameters and a
  token verified for that tenant.
- `app.gleam:handler` accepts string state updates up to 65,536 bytes.
- `document_store.gleam:get_state` distinguishes missing state from its
  1,000 ms call timeout. `merge_state` enqueues work without waiting for a reply.

## Side effects

- `auth.gleam:new_secret` obtains 32 random bytes.
- `document_store.gleam:start` starts an actor; store operations read or merge
  its state and invalidate the encoded cache after successful merges.
- `app.gleam:handler` replies, broadcasts, and logs store failures.
- `router.gleam:handle_request` serves static content and HTML containing a
  demo-tenant token.

## Verification

From the repository root: `cd examples/collab_docs && gleam build`.
The example's `pnpm test` runs Playwright.
