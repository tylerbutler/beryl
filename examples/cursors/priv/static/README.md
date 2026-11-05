# Cursor browser client

## Overview

The page script renders shared cursors and reactions through Phoenix channels.

## Interface

- `app.js` joins `cursor:lobby` and expects `canvas`, `reaction-toolbar`, and
  `user-list` page elements. It exports no module API.

## Invariants

- `app.js:THROTTLE_MS` limits cursor sends to one per 50 ms.
- `app.js:CURSOR_TIMEOUT_MS` expires remote cursors after five seconds.

## Side effects

- `app.js` prompts for a username, opens a WebSocket, sends cursor/reaction
  events, changes the DOM, and schedules cleanup timers.

## Verification

From the repository root: `pnpm -C examples/cursors test`.
The Playwright configuration starts `gleam run` and uses `PORT` or port 8000.
