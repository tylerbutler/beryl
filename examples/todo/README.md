# Realtime Lustre Todo

A small server-authoritative Todo app built with Lustre, Beryl, and Mist. The
BEAM server owns the list and monotonic IDs; every browser joins the fixed
`todos` topic and applies canonical snapshots, replies, and broadcasts.

Commit [`60e841b`](https://github.com/tylerbutler/beryl/commit/60e841b) is the
standalone Lustre baseline. It uses the same domain and UI with `localStorage`,
so the next commit shows exactly what adding Beryl entails.

## Run locally

From `examples/todo`:

```sh
pnpm build
gleam run
```

Open <http://localhost:8011> in two browser windows.

`pnpm dev` runs both commands. The Lustre production build writes into
`priv/static/`, which the Todo server serves with the generated JavaScript and
CSS.

## Architecture

```text
Browser (Lustre + official Phoenix client)
  │  Phoenix Channels protocol
Mist / beryl_mist
  │
Beryl app dispatch — fixed "todos" topic
  │
Supervised in-memory Todo actor
```

The join reply replaces the browser snapshot. `add_todo`, `toggle_todo`, and
`delete_todo` mutate the actor, then return and broadcast the canonical server
result. The client never writes an offline cache.

## Test

```sh
gleam test
cd client && gleam test && cd ..
pnpm test
```

Playwright builds the Lustre client, starts the final Gleam server, and checks
single-browser CRUD, two-browser synchronization, late joins, validation, and
Phoenix wire frames.
