# Document browser assets

## Overview

This subtree holds the editor UI and the generated document-client bundle.

## Subdirectories and boundaries

- [Static UI](./static/README.md): Phoenix integration and DOM editing.

## Interface

`static/app.js` consumes the generated `collab_docs_client.mjs` API.
The [client package](../client/README.md) owns that API.

## Invariants

The browser requires its editor elements before startup (`static/app.js`).
Treat the bundle as output of `scripts/bundle-client.mjs`, not independent source.

## Side effects

The browser opens a channel, pushes state, and edits the DOM (`static/app.js`).
The bundler writes the generated asset.

## Verification

From the repository root: `pnpm -C examples/collab_docs build:client`,
then `pnpm -C examples/collab_docs test`.
