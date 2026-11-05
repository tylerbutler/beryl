# beryl examples

## Overview

This tree contains runnable examples, tutorial checkpoints, a benchmark target,
and shared example helpers. Each Gleam package has its own manifest.
The root `gleam.toml` includes `examples/**` in the workspace and excludes
the tree from release.

## Subdirectories and boundaries

- [Chat rooms](./chatrooms/README.md): authenticated chat, lobby invalidations,
  groups, and capped session presence.
- [Collaborative documents](./collab_docs/README.md): tenant-signed document
  channels, an actor store, and a nested JavaScript CRDT client.
- [Cursors](./cursors/README.md): raw per-topic dispatch, cursor movement,
  reactions, and browser presence.
- [Shared helpers](./example_helpers/README.md): example-local ETS tracking,
  publishing, payload, color, and HTTP utilities.
- [Live poll](./live_poll/README.md): five tutorial checkpoints on ports 8101–8105.
- [Load target](./load_test/README.md): matching Mist/Ewe benchmark behavior and stats.
- [Lustre presence](./lustre_presence/README.md): signed browser sessions and a
  nested Lustre/JavaScript client.
- [Portable channels](./portable_channels/README.md): a Cloudflare Durable
  Object host for bounded protocol transitions and Roost framing.
- [Showcase](./showcase/README.md): sibling demo composition behind one server;
  its document HTTP route remains disabled.

## Interface

The child contracts identify executable modules, handler factories, and
browser APIs. The manifests declare local package ownership: most server
examples use beryl and transport path dependencies; `portable_channels`
uses the portable protocol package and Roost. The nested document and
Lustre clients are separate JavaScript-targeted Gleam packages.

## Invariants

- The root `gleam.toml:tools.trellis.exclude` excludes examples from release.
  Workspace tests also exclude `chatrooms`, `cursors`, and
  `lustre_presence/client`; a successful workspace test run does not cover them.
- Follow each package's runtime boundary: BEAM examples own listeners and
  processes; `portable_channels/worker.mjs:Match` owns Durable Object state.
- `collab_docs/scripts/bundle-client.mjs` and
  `lustre_presence/scripts/bundle-client.mjs` own generated browser bundles.
- Chat, document, and Lustre login credentials here are demo mechanisms;
  their child contracts state the implemented validation.

## Side effects

Server entry points start listeners and long-lived processes. Browser scripts
open WebSockets, change the DOM, and schedule timers. Shared presence helpers
change ETS state; the portable worker changes Durable Object storage and alarms.
Bundlers write static assets. Consult each child for the owning symbols.

## Verification

Use the per-example build and test commands in the linked contracts.
For example, from the repository root:

```sh
cd examples/chatrooms && gleam build
```

Browser verification uses the declared package scripts, such as
`pnpm -C examples/chatrooms test`. Lustre uses Node plus Gleam tests;
portable channels uses Gleam plus local Cloudflare Vitest tests.
The `examples/package.json` provides pnpm/Playwright workspace dependencies,
not a root test script.
