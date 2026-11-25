# Chat browser client

## Overview

The page script connects the chat UI to Phoenix channels.
The separate tutorial module connects `/phoenix` to the public tutorial
endpoint using the official Phoenix client.

## Interface

- `app.js:joinRoom` switches room channels while `lobbyChannel` stays joined.
- `app.js:refreshRoomCounts` fetches the room directory;
  `updateUserList` renders presence. The script exports no module API.
- `phoenix_tutorial.js` exports its Phoenix `Socket` as the default export,
  as the official tutorial does. It uses `room:lobby` and `new_msg` with
  `{body}` payloads.

## Invariants

- `app.js:refreshRoomCounts` applies only the latest room-count request's result.
- `app.js:joinRoom` replaces the active room without replacing the lobby channel.
- `phoenix_tutorial.js` imports the official `phoenix@1.8.17` CDN module with
  no custom serializer or transport. Its MIT notice is in
  `phoenix_tutorial.LICENSE.txt`.

## Side effects

- `app.js` prompts for a username, connects a WebSocket, fetches room counts,
  changes the DOM, sends events, and schedules timers.
- `phoenix_tutorial.js` opens a separate WebSocket, sends messages on Enter,
  and appends broadcast bodies as text.

## Verification

From the repository root: `pnpm -C examples/chatrooms test`.
`package.json:scripts.test` runs Playwright; its configuration starts `gleam run`
on port 8001.
