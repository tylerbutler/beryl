# beryl examples showcase

A single Gleam app that bundles the three example demos behind a landing
page so they can be deployed together as one Railway service:

- `/`         — landing page with links to each demo
- `/cursors`  — collaborative cursors
- `/chat`     — chat rooms
- `/docs`     — collaborative CRDT docs
- `/healthz`  — health check
- `/socket/websocket` — shared WebSocket endpoint (one `beryl.Sockets` app
  routes `cursor:*`, `room:*`, and `document:*:*` through a single `update`
  function, composed from each example's embeddable `Model`/`update` triple)

## How it works

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
