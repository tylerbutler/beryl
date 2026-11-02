# Collaborative Cursors Demo

## Overview

A real-time collaborative cursors and reactions demo built with [beryl](https://github.com/tylerbutler/beryl). Move your mouse to share your cursor, then select a reaction and click the canvas to send it to everyone in the room.

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

## Building with Docker locally

The package depends on the local `beryl` package via `path = "../../packages/beryl"`, so the
build context **must be the repository root**, not `examples/cursors`:

```bash
# From the repository root:
docker build -f examples/cursors/Dockerfile -t beryl-cursors .
docker run --rm -p 8000:8000 beryl-cursors
```

Running `docker build .` from inside `examples/cursors/` will fail because the
parent `beryl` source is outside the build context.

## Deploying to Railway

The example ships with a [`Dockerfile`](./Dockerfile). This checkout has no
`examples/cursors/railway.toml`; supply that configuration before using the
Railway instructions below.

1. Create a new Railway service from this repository.
2. In the service settings, set **Root Directory** to the repository root (not `examples/cursors`) so the Docker build context can see the local `beryl` package referenced via `path = "../../packages/beryl"`.
3. Set **Config Path** to `examples/cursors/railway.toml`.
4. Deploy. Railway injects `PORT`; the Dockerfile sets `BIND_ADDRESS=0.0.0.0`.

The Phoenix JS client in `priv/static/app.js` uses a relative `/socket` URL, so it automatically negotiates `wss://` over Railway's TLS-terminated proxy.

## What it demonstrates

| beryl Feature | How It's Used |
|---|---|
| **App dispatch** | `cursor:*` topics handle join/leave and cursor events |
| **Topic patterns** | Wildcard `cursor:*` routing matches any cursor room |
| **Session presence (ETS)** | The example-local `session_presence` tracker stores connected users and their username + color metadata in ETS |
| **PubSub** | `broadcast_from` fans out cursor moves and reactions to all other clients |
| **Wire protocol** | Phoenix-compatible format — works with the official Phoenix JS client |
| **WebSocket transport** | `mist_transport.upgrade()` handles Phoenix-compatible WebSocket requests |
| **Rate limiting** | Throttles high-frequency cursor movement messages |

## Architecture

```
Browser (vanilla JS + Phoenix client)
  ├── cursor movement
  └── selectable, animated reactions
Server (Gleam)
  ├── Mist HTTP routing ── serves HTML + static files
  ├── beryl app-side dispatch ── cursor:* topics (cursor/app)
  ├── example session_presence ── ETS-backed user tracking
  └── beryl pubsub ── broadcast cursor positions and reactions
```

## Stack

- **Backend**: Gleam, beryl, mist
- **Frontend**: Vanilla JS, CSS animations, [Phoenix JS client](https://www.npmjs.com/package/phoenix) (CDN)
- **No build step** — just `gleam run`

## Subdirectories and boundaries

- [Server source](./src/README.md): startup, raw topic dispatch, and HTTP routing.
- [Browser assets](./priv/README.md): cursor/reaction channel and DOM integration.

## Interface

`src/cursor.gleam:main` starts the Erlang package named `cursor`.
`src/cursor/app.gleam:cursor_rooms_init` and `cursor_rooms_update` implement
socket-wide dispatch; `router.gleam:handle_request` supplies HTTP routing.
`gleam.toml` declares the shared helpers and beryl/Mist as path dependencies.

## Invariants

- `src/cursor/app.gleam:cursor_rooms_update` keeps a separate model per topic.
- `src/cursor/app.gleam:decode_reaction` requires supported reactions and
  coordinates within 0–1.
- `priv/static/app.js:THROTTLE_MS` throttles sends to 50 ms;
  `CURSOR_TIMEOUT_MS` expires remote cursors after five seconds.

## Side effects

`src/cursor.gleam:main` starts presence, supervision, and the listener.
The app tracks/untracks sessions and broadcasts events; the browser opens
a WebSocket and changes the DOM.

## Verification

From the repository root: `cd examples/cursors && gleam build`;
`pnpm -C examples/cursors test` runs Playwright with `PORT` or port 8000.
The root workspace test task excludes this package.
