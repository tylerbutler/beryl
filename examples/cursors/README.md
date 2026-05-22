# Collaborative Cursors Demo

A real-time collaborative cursors demo built with [beryl](https://github.com/tylerbutler/beryl) — move your mouse and see other users' cursors in real-time.

## Running

```bash
cd examples/cursors
gleam run
```

Then open <http://localhost:8000> in **multiple browser tabs** to see cursors move in real-time.

### Environment variables

| Var | Default | Purpose |
|---|---|---|
| `PORT` | `8000` | TCP port the HTTP/WebSocket server binds to |
| `BIND_ADDRESS` | `localhost` | Interface to bind. Set to `0.0.0.0` when running in a container or behind a proxy. |

## Deploying to Railway

The example ships with a [`Dockerfile`](./Dockerfile) and [`railway.toml`](./railway.toml).

1. Create a new Railway service from this repository.
2. In the service settings, set **Root Directory** to the repository root (not `examples/cursors`) so the Docker build context can see the local `beryl` package referenced via `path = "../.."`.
3. Set **Config Path** to `examples/cursors/railway.toml`.
4. Deploy. Railway injects `PORT`; the Dockerfile sets `BIND_ADDRESS=0.0.0.0`.

The Phoenix JS client in `priv/static/app.js` uses a relative `/socket` URL, so it automatically negotiates `wss://` over Railway's TLS-terminated proxy.

## What It Demonstrates

| beryl Feature | How It's Used |
|---|---|
| **Channels** | `cursor:lobby` channel handles join/leave and cursor events |
| **Topic patterns** | Wildcard `cursor:*` routing matches any cursor room |
| **Presence (CRDT)** | Tracks connected users with username + color metadata |
| **PubSub** | `broadcast_from` fans out cursor moves to all other clients |
| **Wire protocol** | Phoenix-compatible format — works with the official Phoenix JS client |
| **WebSocket transport** | `mist_transport.upgrade()` handles Phoenix-compatible WebSocket requests |
| **Rate limiting** | Throttles high-frequency cursor movement messages |

## Architecture

```
Browser (vanilla JS + Phoenix client)
  │
  │  WebSocket (Phoenix wire protocol)
  │
Server (Gleam)
  ├── Mist HTTP routing ── serves HTML + static files
  ├── beryl channels ── cursor:* topic handler
  ├── beryl presence ── CRDT-backed user tracking
  └── beryl pubsub ── broadcast cursor positions
```

## Stack

- **Backend**: Gleam, beryl, mist
- **Frontend**: Vanilla JS, [Phoenix JS client](https://www.npmjs.com/package/phoenix) (CDN)
- **No build step** — just `gleam run`
