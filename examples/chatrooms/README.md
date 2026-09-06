# Chat Rooms — beryl demo

A multi-room chat application demonstrating beryl's real-time channels, groups,
and authentication features with example-local, ETS-backed session presence.

## Quick Start

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
- ✅ **Message acknowledgment** — server confirms delivery with `Reply`
- ⚠️ **Input validation** — empty messages rejected with `error_with_code(422, ...)`
- 📢 **System messages** — "user joined" / "user left" via server `Push`
- 🏷️ **Room groups** — rooms organized in named groups via `group.broadcast()`
- 🚦 **Rate limiting** — join rate (5/sec) and per-channel rate (10/sec)

## beryl Features Exercised

This demo is designed to complement the [cursors demo](../cursors/) by exercising **different** beryl features:

| Feature | Module | Usage |
|---|---|---|
| **Groups** | `beryl/group` | Rooms organized in "public" group |
| **on_connect auth** | `beryl_mist` | Token query param validated before WS upgrade |
| **RejectJoin** | `beryl/socket` | Room capacity check rejects when full |
| **ReplyOk** | `beryl/socket` | Message delivery confirmed on the client's ref |
| **Broadcast** | `beryl/socket` | System join/leave messages broadcast to room |
| **error code** | `chatroom/app` | Empty message validation returns code 422 |
| **Topic helpers** | `beryl/topic` | Extract room name from `room:*` pattern |
| **Session presence** | `example_helper/session_presence` | ETS-backed online users and typing metadata |
| **join_rate** | `beryl` | 5 joins/sec per socket |
| **channel_rate** | `beryl` | 10 msg/sec per channel |
| **Multiple topics** | `beryl` | Each room is a separate topic |
| **Multiple channel types** | `beryl/socket` | Exact `lobby` topic plus wildcard `room:*` topics on one socket |
| **Ordered dispatch** | `beryl/socket` | Session tracker changes happen before lobby invalidations |

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

## Running Tests

```bash
npm install           # First time only
npx playwright test   # 43 e2e tests
```

## API

- `GET /` — Chat UI (requires `?token=beryl-demo`)
- `GET /api/rooms` — JSON list of rooms with user counts
- `GET /static/*` — Static assets (CSS, JS)
- `WS /socket/websocket?token=beryl-demo` — WebSocket endpoint

## Channel Events

| Direction | Event | Purpose |
|---|---|---|
| Client → Server | `new_msg` | Send a chat message `{text}` |
| Client → Server | `typing` | Start typing indicator |
| Client → Server | `stop_typing` | Stop typing indicator |
| Server → Client | `new_msg` | Broadcast message `{text, username, color, type, timestamp}` |
| Server → Client | `msg_ack` | Delivery acknowledgment sent as `phx_reply` to the original `new_msg` ref `{status: "ok"}` |
| Server → Client | `msg_error` | Validation error `{code, error}` |
| Server → Client | `presence_list` | Updated online user list |
| Server → Client | `typing` | Typing indicator update |
| Server → Client | `rooms_changed` on `lobby` | Invalidate room counts after room membership changes `{room}` |

The browser joins `lobby` once and keeps it joined while replacing its active
`room:*` channel. `rooms_changed` invalidates the directory; the browser then
loads the current counts from `GET /api/rooms`.
