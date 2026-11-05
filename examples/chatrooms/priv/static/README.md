# Chat browser client

## Overview

The page script connects the chat UI to Phoenix channels.

## Interface

- `app.js:joinRoom` switches room channels while `lobbyChannel` stays joined.
- `app.js:refreshRoomCounts` fetches the room directory;
  `updateUserList` renders presence. The script exports no module API.

## Invariants

- `app.js:refreshRoomCounts` applies only the latest room-count request's result.
- `app.js:joinRoom` replaces the active room without replacing the lobby channel.

## Side effects

- `app.js` prompts for a username, connects a WebSocket, fetches room counts,
  changes the DOM, sends events, and schedules timers.

## Verification

From the repository root: `pnpm -C examples/chatrooms test`.
`package.json:scripts.test` runs Playwright; its configuration starts `gleam run`
on port 8001.
