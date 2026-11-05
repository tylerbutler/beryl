# Chat Rooms — beryl demo

## Overview

A multi-room chat application demonstrating beryl's real-time channels, groups,
and authentication features with example-local, ETS-backed session presence.

## Quick start

```bash
cd examples/chatrooms
gleam run
# Open http://localhost:8001?token=beryl-demo in multiple browser tabs
```

## Features

- 💬 **Multi-room chat** — switch between rooms (general, random, help)
- 🧭 **Persistent lobby channel** — one socket stays joined to `lobby` while switching between `room:*` topics
- 🔢 **Live room counts** — lobby invalidations refresh authoritative counts from `/api/rooms`
- 🔐 **Connection authentication** — `on_connect` hook validates auth token before WebSocket upgrade
- 👥 **Live presence** — see who's online in each room
- ✍️ **Typing indicators** — see when others are typing
- ❌ **Join rejection** — rooms reject joins when full (20 users max)
- ✅ **Message acknowledgment** — server confirms delivery with `channel.reply_ok`
- ⚠️ **Input validation** — empty messages rejected with `error_with_code(422, ...)`
- 📢 **System messages** — "user joined" / "user left" via `channel.broadcast`
- 🏷️ **Room groups** — `group.topics` checks membership in the "public" group
- 🚦 **Rate limiting** — join rate (5/sec) and per-channel rate (10/sec)

## beryl features exercised

This demo is designed to complement the [cursors demo](../cursors/README.md) by exercising **different** beryl features:

| Feature | Module | Usage |
|---|---|---|
| **Groups** | `beryl/group` | Rooms organized in "public" group |
| **on_connect auth** | `beryl_mist` | Token query param validated before WS upgrade |
| **Join rejection** | `beryl/channel` | Room capacity check rejects when full |
| **Replies** | `beryl/channel` | Message delivery confirmed on the client's ref |
| **Broadcasts** | `beryl/channel` | System join/leave messages broadcast to room |
| **error code** | `chatroom/app` | Empty message validation returns code 422 |
| **Topic parameters** | `beryl/channel` | Read the room name from `JoinContext.parameters` for `room:*` |
| **Session presence** | `example_helper/session_presence` | ETS-backed online users and typing metadata |
| **join_rate** | `beryl` | 5 joins/sec per socket |
| **channel_rate** | `beryl` | 10 msg/sec per channel |
| **Multiple topics** | `beryl` | Each room is a separate topic |
| **Multiple channel types** | `beryl/channel` | Exact `lobby` topic plus wildcard `room:*` topics on one socket |
| **Ordered dispatch** | `example_helper/session_presence` | Session tracker changes happen before lobby invalidations |

## Architecture

```
Browser (vanilla JS + Phoenix client CDN)
  ↕ WebSocket (Phoenix wire protocol, token auth)
Gleam/BEAM server (port 8001)
  ├── Mist HTTP routing (static files, /api/rooms)
  ├── Mist WebSocket transport (on_connect auth)
  ├── beryl app-side dispatch
  │   ├── lobby (persistent room-directory invalidation channel)
  │   └── room:* (replaceable chat-room channels)
  ├── beryl groups ("public" → general, random, help)
  └── example session_presence (ETS-backed online users + typing indicators)
```

## Running tests

```bash
npm install           # First time only
npx playwright test   # 43 e2e tests
```

## API

- `GET /` — Chat UI (no HTTP authentication; `?token=beryl-demo` supplies the browser's WebSocket token)
- `GET /api/rooms` — JSON list of rooms with user counts
- `GET /static/*` — Static assets (CSS, JS)
- `WS /socket/websocket?token=beryl-demo` — WebSocket endpoint

## Channel events

| Direction | Event | Purpose |
|---|---|---|
| Client → Server | `new_msg` | Send a chat message `{text}` |
| Client → Server | `typing` | Start typing indicator |
| Client → Server | `stop_typing` | Stop typing indicator |
| Server → Client | `new_msg` | Broadcast message `{text, username, color, type, timestamp}` |
| Server → Client | `phx_reply` for `new_msg` | Status `"ok"` with response `{status: "ok", timestamp}` on success, or `{code: 422, error}` for an empty message |
| Server → Client | `presence_list` | Updated online user list |
| Server → Client | `typing` | Typing indicator update |
| Server → Client | `rooms_changed` on `lobby` | Invalidate room counts after room membership changes `{room}` |

The browser joins `lobby` once and keeps it joined while replacing its active
`room:*` channel. `rooms_changed` invalidates the directory; the browser then
loads the current counts from `GET /api/rooms`.

## Subdirectories and boundaries

- [Server source](./src/README.md): startup, channel handlers, router, and timestamp FFI.
- [Browser assets](./priv/README.md): lobby/room client and presence UI.

## Interface

`src/chatroom.gleam:main` starts the Erlang package named `chatroom`.
`src/chatroom/app.gleam:handlers` supplies lobby and room channels;
`src/chatroom/router.gleam:handle_request` supplies HTTP routing.
`gleam.toml` declares path dependencies on beryl, its Mist transport, and
the shared example helpers.

## Invariants

- `src/chatroom.gleam:main` validates `beryl-demo` at WebSocket connection time.
- `src/chatroom/app.gleam:room` requires public-group membership;
  `max_room_users` limits tracked room occupancy to 20.
- `src/chatroom/app.gleam:new_message` rejects empty messages.

## Side effects

`src/chatroom.gleam:main` starts processes and listeners and creates demo rooms.
Channel callbacks change session presence and broadcast updates; the browser
fetches counts, opens channels, and updates the DOM.

## Verification

From the repository root: `cd examples/chatrooms && gleam build`.
`pnpm -C examples/chatrooms test` runs Playwright and starts the server on
port 8001. The root workspace test task excludes this package, so that task
does not verify this example.
