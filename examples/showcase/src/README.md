# Showcase server source

## Overview

The entry point assembles channel handlers, example resources, and the shared
HTTP/WebSocket server.

## Interface

- `showcase.gleam:handlers` builds the channel table. Its OTP `start` callback
  prepares the application supervisor. `main` starts the server under it.
- [Router and channels](./showcase/README.md) define HTTP and per-topic boundaries.

## Invariants

- `showcase.gleam` configures frame/message/join rates of 35/30/5 per
  second, cursor topic rate 30, and room/document topic rates 10.
- `showcase.gleam:handlers` composes separate handlers with per-topic state.

## Side effects

The application owns presence, the document store, and the broadcast hub.
The server supervisor starts the seeded groups actor and beryl before Ewe.
It stops Ewe first on shutdown.

## Verification

From the repository root: `cd examples/showcase && gleam build`.
`gleam test` checks package behavior; `pnpm test` runs Playwright on port 8010.
