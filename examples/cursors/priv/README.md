# Cursor browser assets

## Overview

This subtree holds the collaborative cursor page's browser assets.

## Subdirectories and boundaries

- [Static client](./static/README.md): cursor movement, reactions, and presence UI.

## Interface

`static/app.js` joins `cursor:lobby` and integrates with the page DOM.
It exports no module API.

## Invariants

`static/app.js:THROTTLE_MS` sets a 50 ms send interval;
`CURSOR_TIMEOUT_MS` expires remote cursors after five seconds.

## Side effects

The browser opens a WebSocket, sends events, changes DOM state, and schedules
timers (`static/app.js`).

## Verification

From the repository root: `pnpm -C examples/cursors test` (Playwright).
