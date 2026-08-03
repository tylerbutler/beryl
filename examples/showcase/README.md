# beryl examples showcase

A single Gleam app that bundles the three example demos behind a landing
page so they can be deployed together as one Railway service:

- `/`         — landing page with links to each demo
- `/cursors`  — collaborative cursors
- `/chat`     — chat rooms
- `/docs`     — collaborative CRDT docs
- `/healthz`  — health check
- `/socket/websocket` — shared WebSocket endpoint (one `beryl.Sockets` app
  with a `beryl_channels` handler per topic namespace: `cursor:*`,
  `room:*`, and `document:*:*`)

## Channels

This is the multi-topic app the `beryl_channels` layer exists for. Each
namespace is a channel handler in `src/showcase/channels/`, registered as
one list in `showcase.handlers`; the layer routes every join, message, and
close to the handler that owns the topic, and each channel keeps its own
private state per joined topic. There is no socket-wide model, no message
union, and no hand-written router.

The standalone `cursors`, `chatrooms`, and `collab_docs` servers stay on
raw `beryl.start` dispatch on purpose: each serves a single topic
namespace, which the core API already handles directly.

Two things a topic-scoped channel cannot express itself go through
`showcase/hub`, a small actor holding the `beryl.Sockets` handle (the
equivalent of Phoenix's `Endpoint.broadcast/3`): the `lobby` room-list
announcement, which targets another topic, and the leave-time
`presence_list` snapshot, because `on_terminate` returns no actions.

## Tests

```sh
cd examples/showcase
gleam test      # channel behavior over the transport SPI
pnpm test       # Playwright end-to-end against a running server
```

## Routing

Each example's router was refactored to accept a `base_path` field on its
`Context`. The standalone demos still pass `""` and serve assets at
`/static/...`. The showcase passes `"/cursors"`, `"/chat"`, and `"/docs"`
respectively, so each example's HTML emits prefixed asset URLs and its
`serve_static` mount lives under the prefix. The Phoenix JS client in
each example uses `new Socket("/socket")` so all three share the same
WS endpoint without any client-side edits.

## Run locally

```sh
cd examples/showcase
gleam run
# then open http://localhost:8000
```

Honors `PORT` and `BIND_ADDRESS` like the standalone cursors demo.

## Run in Docker

The Dockerfile expects the **repo root** as build context because the
project depends on `beryl` and the three example projects via relative
path dependencies.

```sh
# from the repository root
docker build -f examples/showcase/Dockerfile -t beryl-showcase .
docker run --rm -p 8000:8000 -e PORT=8000 beryl-showcase
```

## Deploy to Railway

Point the Railway service at this repo with:

- Root directory: repository root
- Config path: `examples/showcase/railway.toml`

`railway.toml` selects `examples/showcase/Dockerfile` and a `/healthz`
health check.
