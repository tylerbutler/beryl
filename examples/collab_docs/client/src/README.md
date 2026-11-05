# Document client model

## Overview

This JavaScript-targeted Gleam module owns the browser document API.
The CRDT implementations come from the declared lattice dependencies.

## Interface

- `collab_docs_client.gleam:Document`, `RenderBlock`, and `DocumentError`
  describe the document boundary.
- `new_document`, `json_to_document`, and `document_to_json` construct and
  serialize documents.
- `add_block`, `edit_block`, `remove_block`, `merge_json`, and
  `merge_json_or_keep` update documents; `blocks` and `blocks_json` render
  their contents. `document_error_to_string` formats errors.

## Invariants

- `collab_docs_client.gleam:Document` is opaque.
- `collab_docs_client.gleam:add_block` and `edit_block` reject invalid block
  identifiers; edits require the expected identifier.
- `collab_docs_client.gleam:blocks` sorts block identifiers and register values.

## Side effects

None. The document functions return values;
the browser integration owns DOM and network work.

## Verification

From the repository root: `cd examples/collab_docs/client && gleam build`.
The package targets JavaScript and declares `unitest` development dependencies.
