# Live-poll tutorial

## Overview

Five runnable checkpoints progress from raw socket callbacks to composed
channels and explicit runtime limits.

## Subdirectories and boundaries

- [Source](./src/README.md): poll model, shared actors, handlers, and checkpoints.

## Interface

`gleam.toml:name` identifies the Erlang package `live_poll`.
`src/live_poll/step_01.gleam:main` through `step_05.gleam:main` start the
stages on ports 8101–8105. `server.gleam:run` hosts each checkpoint.

## Invariants

- `src/live_poll/poll.gleam:vote` requires an open poll; `close` is idempotent.
- `src/live_poll/raw.gleam:update` gates commands by stage and joined topic.
- `src/live_poll/store.gleam:leave` removes state when the last member leaves.

## Side effects

`src/live_poll/server.gleam:run` starts supervision and Mist and blocks
indefinitely. The store and timer actors send messages; handlers broadcast
state and closure events.

## Verification

From the repository root: `cd examples/live_poll && gleam build`.
For an interactive stage, run `gleam run -m live_poll/step_01` from that
directory, substituting `step_02` through `step_05` for later checkpoints.
The manifest declares `unitest`; no browser-test script is declared here.
