# Live-poll source

## Overview

This source tree groups the tutorial checkpoints and their shared poll runtime.

## Subdirectories and boundaries

- [Poll modules](./live_poll/README.md): model, actor store, timer, raw/composed
  handlers, server, and five runnable checkpoints.

## Interface

`live_poll/step_01.gleam:main` through `step_05.gleam:main` start the checkpoints.
`live_poll/server.gleam:run` hosts each stage.

## Invariants

`live_poll/poll.gleam:vote` requires an open poll; `close` is idempotent.
The raw dispatcher requires joined, non-empty poll-room topics.

## Side effects

`live_poll/server.gleam:run` starts supervision and a listener;
store/timer modules send actor messages and schedule work.

## Verification

From the repository root: `cd examples/live_poll && gleam build`.
This source tree has explicit checkpoint modules rather than a default
`live_poll.gleam` executable; use `gleam run -m live_poll/step_01` to run a stage.
