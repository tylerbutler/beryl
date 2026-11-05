# Realtime Lustre Todo

A small server-authoritative Todo app built with Lustre, beryl, and Mist. The
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

The client reads a fresh snapshot after its subscription is established and
after each mutation event. Snapshot replies are ordered by each socket's
request loop. Mutation acknowledgements update the form, not the list, so a
delayed acknowledgement cannot overwrite a newer snapshot.

`add_todo`, `toggle_todo`, and `delete_todo` mutate the actor. The actor
publishes each committed result before acknowledging it, independent of the
requesting socket. If broadcast admission fails, it rejects the mutation
without changing the list. Failed snapshot reads retry with a delay capped at
five seconds. Queued requests expire after one second. A timeout is not a
guarantee that a request already being handled did not commit; reconnect or
read a snapshot to check the outcome. The client never writes an offline cache.

The supervisor uses `RestForOne`: if the in-memory store restarts, the socket
runtime restarts too. Browsers reconnect and replace their old snapshots.
All browsers share one public list; this example has no account isolation or
persistent storage.

## Test

```sh
gleam test
cd client && gleam test && cd ..
pnpm test
```

Playwright builds the Lustre client, starts the final Gleam server, and checks
single-browser CRUD, two-browser synchronization, late joins, validation, and
Phoenix wire frames.
