# Document client package

## Overview

This nested Gleam package builds the document model for JavaScript.

## Subdirectories and boundaries

- [Client source](./src/README.md): opaque documents, block editing, CRDT
  merging, and rendering data.

## Interface

`gleam.toml:name` identifies `collab_docs_client`; `target` selects JavaScript.
`src/collab_docs_client.gleam:Document` is the package's document boundary.
Lattice dependencies own the CRDT implementations.

## Invariants

The source keeps `Document` opaque and validates block identifiers
(`src/collab_docs_client.gleam:Document`, `add_block`, `edit_block`).

## Side effects

The source API has no external I/O. The parent bundling script owns generated
browser output.

## Verification

From the repository root: `cd examples/collab_docs/client && gleam build`.
This package declares `unitest`; it is not in the root workspace test exclusions.
