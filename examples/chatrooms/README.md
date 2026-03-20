# Chat Rooms — beryl demo

A multi-room chat application demonstrating beryl's real-time channels, groups, presence, and authentication features.

## Quick Start

```bash
cd examples/chatrooms
gleam run
# Open http://localhost:8001?token=beryl-demo in multiple browser tabs
```

## Features

- 💬 **Multi-room chat** — switch between rooms (general, random, help)
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
| **on_connect auth** | `beryl/transport/websocket` | Token query param validated before WS upgrade |
| **JoinError** | `beryl/channel` | Room capacity check rejects when full |
| **Reply** | `beryl/channel` | Message delivery confirmed with `msg_ack` |
| **Push** | `beryl/channel` | System join/leave messages broadcast to room |
| **error_with_code** | `beryl/channel` | Empty message validation returns code 422 |
| **Topic helpers** | `beryl/topic` | Extract room name from `room:*` pattern |
| **Presence typing** | `beryl/presence` | Typing indicators via presence meta updates |
| **join_rate** | `beryl` | 5 joins/sec per socket |
| **channel_rate** | `beryl` | 10 msg/sec per channel |
| **Multiple topics** | `beryl` | Each room is a separate topic |

## Architecture

```
Browser (vanilla JS + Phoenix client CDN)
  ↕ WebSocket (Phoenix wire protocol, token auth)
Gleam/BEAM server (port 8001)
  ├── wisp router (on_connect auth, static files, /api/rooms)
  ├── beryl channels (room:* handler)
  ├── beryl groups ("public" → general, random, help)
  ├── beryl presence (online users + typing indicators)
  └── inline wisp→mist adapter
```

## Running Tests

```bash
npm install           # First time only
npx playwright test   # 35 e2e tests
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
| Server → Client | `msg_ack` | Delivery confirmation `{status: "ok"}` |
| Server → Client | `msg_error` | Validation error `{code, error}` |
| Server → Client | `presence_list` | Updated online user list |
| Server → Client | `typing` | Typing indicator update |
