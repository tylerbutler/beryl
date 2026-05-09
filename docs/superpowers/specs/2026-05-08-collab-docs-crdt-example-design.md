# Collaborative CRDT Documents Example Design

## Problem

Beryl has runnable examples for cursors and chatrooms, but no example that demonstrates Beryl as transport for a real collaborative data model. The proposed example uses lattice CRDT packages to show client-side CRDT convergence over Beryl channels without server-assigned sequence numbers or a globally ordered operation log.

## Goals

- Add a runnable `examples/collab_docs` app demonstrating collaborative document blocks.
- Run CRDT merge logic in browser clients with a Gleam-to-JavaScript client package.
- Use Beryl only as realtime transport plus optional snapshot cache, not as an ordering authority.
- Demonstrate segment wildcard routing with `document:*:*`.
- Show conflict behavior explicitly when two clients concurrently edit the same block.

## Non-goals

- Full rich-text or character-level CRDT editing.
- Persistent storage beyond an in-memory server cache.
- Offline-first sync across browser reloads.
- Server-assigned global sequence numbers.
- A complete CRDT library tutorial.

## Architecture

The example is a single runnable app at `examples/collab_docs` with two Gleam packages:

```text
examples/collab_docs/
├── gleam.toml
├── manifest.toml
├── package.json
├── playwright.config.js
├── README.md
├── src/
│   ├── collab_docs.gleam
│   ├── collab_docs_ffi.erl
│   └── collab_docs/
│       ├── channel.gleam
│       ├── doc_store.gleam
│       └── router.gleam
├── client/
│   ├── gleam.toml
│   ├── manifest.toml
│   └── src/collab_docs_client.gleam
├── priv/static/
│   ├── app.js
│   ├── collab_docs_client.mjs
│   └── style.css
└── e2e/collab_docs.spec.js
```

The server package targets Erlang and depends on Beryl, Mist, and Gleam OTP. The client package targets JavaScript and depends on `lattice_core`, `lattice_maps`, and `lattice_registers`, using the compiled module from browser glue code.

## CRDT Data Model

The document state is an `ORMap` whose values are `MVRegister(String)`:

```gleam
or_map.new(replica_id, crdt.MvRegisterSpec)
```

Each map key is a stable `block_id`. Each register value is a JSON string encoding a block:

```json
{
  "id": "block_123",
  "kind": "todo",
  "text": "Draft README",
  "done": false,
  "position": "a0"
}
```

The OR-Map handles block existence and delete/re-add semantics. The MV-Register handles concurrent edits to a single block without trusting client clocks. When a block has one MV value, the UI renders it normally. When it has multiple MV values, the UI renders a conflict card and lets the user choose or create a merged version. That resolution writes a new MV-Register value, causally superseding the visible conflict in that client state.

## Client API

`collab_docs_client.gleam` exposes a small JavaScript-facing API:

- `new_document(replica_id: String) -> Document`
- `from_json(replica_id: String, json: String) -> Result(Document, String)`
- `to_json(document: Document) -> String`
- `add_block(document: Document, block_json: String) -> Document`
- `edit_block(document: Document, block_id: String, block_json: String) -> Document`
- `remove_block(document: Document, block_id: String) -> Document`
- `merge_json(document: Document, remote_json: String) -> Result(Document, String)`
- `blocks(document: Document) -> List(RenderBlock)`
- `blocks_json(document: Document) -> String`
- `merge_json_or_keep(document: Document, remote_json: String) -> Document`

`RenderBlock` is shaped for easy JavaScript rendering: block ID, block kind, position, and either one resolved value or multiple conflict values.

## Beryl Channel Design

The server registers one channel pattern:

```gleam
beryl.register(channels, "document:*:*", handler)
```

The two wildcard captures are `tenant_id` and `doc_id`. The channel uses those values to build a canonical document key such as `tenant_id <> "/" <> doc_id`.

Events:

| Event | Direction | Purpose |
|---|---|---|
| `phx_join` | client -> server | Join one document topic. Join reply includes cached state if available. |
| `sync_state` | client -> server | Send serialized CRDT state after a local change or merge. |
| `doc_state` | server -> clients | Relay serialized state to other clients on the same topic. |
| `state_error` | server -> client | Report invalid JSON/state payload. |

The server uses `broadcast_from` for `doc_state` so the sender does not receive its own state back immediately. Clients still tolerate duplicate states because CRDT merge is idempotent.

## Server Cache

`doc_store.gleam` is an OTP actor keyed by document key. It stores the latest merged server cache state for late joiners. The cache is not authoritative:

- It does not assign sequence numbers.
- It does not reject concurrent states based on order.
- It only validates and merges CRDT JSON envelopes.
- If cache merge fails, the channel replies with `state_error` and leaves client state unchanged.

Late joiners receive the cached state in the join reply. If no cache exists, they start with an empty local document.

## Client Flow

1. Browser creates a client replica ID and local document state.
2. Browser joins `document:demo:welcome`.
3. If join reply contains cached state, browser merges it into local state and renders.
4. User adds, edits, deletes, or resolves a block.
5. Client updates local CRDT state immediately and renders optimistically.
6. Client sends `sync_state` with serialized CRDT state.
7. Server validates, merges into cache, and relays `doc_state` to other clients.
8. Receiving clients merge and render. Message order does not matter.

## Error Handling

- Invalid topic shape is rejected by normal Beryl topic matching.
- Invalid `sync_state` payload gets `state_error`; the socket remains joined.
- CRDT decode or merge failure gets `state_error` with a short code such as `"invalid_state"` or `"merge_failed"`.
- Unknown block IDs in client operations are no-ops in the client module.
- Conflict resolution must include a selected or merged block JSON value; empty resolution is rejected in the browser before send.

## Testing

Playwright e2e tests cover the user-visible CRDT guarantees:

1. Two clients joining the same document converge after independent block additions.
2. Duplicate `doc_state` delivery does not duplicate rendered blocks.
3. Out-of-order state delivery converges to the same rendered block set.
4. Concurrent edits to the same block render a conflict card with multiple versions.
5. Resolving a conflict leaves one normal block after both clients merge the resolved state.
6. Late joiner receives cached state from the server join reply.
7. `document:*:*` routing isolates `document:demo:one` from `document:demo:two`.

Focused Gleam tests cover the client module's pure functions in the JavaScript-target client package. Playwright e2e tests remain the acceptance coverage for browser/server integration.

## Build and Integration

The example uses port `8002`. Integration work:

- Add `collab_docs` to `examples/pnpm-workspace.yaml`.
- Add `examples/collab_docs` dependency download, build, and Playwright test steps to `justfile`.
- Add a client build step that compiles `examples/collab_docs/client` to JavaScript and bundles the browser entry to `priv/static/collab_docs_client.mjs`.
- Update README and website examples docs with the new demo.
- Add a changie fragment because this is user-visible.

## Implementation Decisions

- Client bundle mechanism: use a small bundler step so browser imports are stable and `priv/static/collab_docs_client.mjs` is the only generated client module served by Mist.
- Server cache representation: store decoded `ORMap` values in `doc_store.gleam`; regenerate JSON for join replies and `doc_state` relays.
- Conflict UI shape: render side-by-side block versions with "Use this version" and "Merge manually" actions.

These decisions keep the example deterministic and avoid asking users to import Gleam build internals directly from the browser.
