# Collaborative Cursors Demo

A real-time collaborative cursors demo built with [beryl](https://github.com/tylerbutler/beryl) — move your mouse and see other users' cursors in real-time.

## Running

```bash
cd examples/cursors
gleam run
```

Then open <http://localhost:8000> in **multiple browser tabs** to see cursors move in real-time.

## What It Demonstrates

| beryl Feature | How It's Used |
|---|---|
| **Channels** | `cursor:lobby` channel handles join/leave and cursor events |
| **Topic patterns** | Wildcard `cursor:*` routing matches any cursor room |
| **Presence (CRDT)** | Tracks connected users with username + color metadata |
| **PubSub** | `broadcast_from` fans out cursor moves to all other clients |
| **Wire protocol** | Phoenix-compatible format — works with the official Phoenix JS client |
| **WebSocket transport** | `websocket.upgrade()` middleware in the wisp router |
| **Rate limiting** | Throttles high-frequency cursor movement messages |

## Architecture

```
Browser (vanilla JS + Phoenix client)
  │
  │  WebSocket (Phoenix wire protocol)
  │
Server (Gleam)
  ├── Wisp router ── serves HTML + static files
  ├── beryl channels ── cursor:* topic handler
  ├── beryl presence ── CRDT-backed user tracking
  └── beryl pubsub ── broadcast cursor positions
```

## Stack

- **Backend**: Gleam, beryl, wisp, mist
- **Frontend**: Vanilla JS, [Phoenix JS client](https://www.npmjs.com/package/phoenix) (CDN)
- **No build step** — just `gleam run`
