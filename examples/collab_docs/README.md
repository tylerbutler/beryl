# Collaborative CRDT Docs

This example shows a collaborative document editor built with beryl channels and
client-side CRDT state.

## What it demonstrates

| Feature | How it is used |
|---|---|
| Segment wildcard topics | The server registers `document:*:*` so each tenant/document pair gets an isolated topic. |
| Client-side CRDT merge | The browser keeps document blocks in `lattice_crdt` as an `ORMap(MVRegister(String))`. |
| Unordered realtime transport | Beryl carries document deltas between clients without requiring total message ordering. |
| Late joiner cache | The server caches merged document state and returns it in the join reply for newly connected clients. |
| Conflict UI | Concurrent edits to the same block render explicit conflict cards with each version. |

## Run

```bash
cd examples/collab_docs
gleam run
```

Open <http://localhost:8002> in multiple browser tabs.

## Test

```bash
pnpm -C examples/collab_docs test
```
