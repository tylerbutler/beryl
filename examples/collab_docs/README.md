# Collaborative CRDT Docs

This example shows a collaborative document editor built with beryl app-side
dispatch and client-side CRDT state.

## What it demonstrates

| Feature | How it is used |
|---|---|
| Segment wildcard topics | The server routes `document:*:*` topics so each tenant/document pair gets an isolated topic. |
| Client-side CRDT merge | The browser keeps document blocks with the `lattice_core`, `lattice_maps`, and `lattice_registers` packages as an `ORMap(MVRegister(String))`. |
| Unordered realtime transport | Beryl carries serialized document state updates between clients without requiring total message ordering. |
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
