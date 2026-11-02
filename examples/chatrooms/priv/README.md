# Chat browser assets

## Overview

This subtree holds the browser side of the chat example.

## Subdirectories and boundaries

- [Static client](./static/README.md): lobby/room channels and DOM integration.

## Interface

The child contract describes `static/app.js:joinRoom` and `refreshRoomCounts`;
the server router serves these assets.

## Invariants

`static/app.js:refreshRoomCounts` applies only the latest requested counts.

## Side effects

The browser script connects sockets, fetches room counts, changes the DOM, and
schedules timers (`static/app.js`).

## Verification

From the repository root: `pnpm -C examples/chatrooms test` (Playwright).
