# Live-poll checkpoints

## Overview

The tutorial progresses from raw socket callbacks to composed channels and
a configuration with explicit limits.

## Interface

- `poll.gleam:Choice`, `Status`, `Poll`, `VoteError`, `CloseResult`, `Command`,
  `new`, `command`, `vote`, `close`, `to_json`, and `error_to_json` expose the poll model.
- `store.gleam:Store`, `CloseResult`, `start`, `join`, `leave`, `get`, `vote`, and `close`
  expose the actor-backed room store.
- `timer.gleam:Timer`, `start`, and `after` expose scheduled actions.
- `raw.gleam:Stage`, `Message`, `Model`, `init`, and `update` implement raw dispatch.
- `channel_handler.gleam:PollInfo` and `handlers` supply composed handlers.
- `server.gleam:HealthEndpoint`, `GuideChannel`, and `run` configure the server.
- `step_01.gleam:main` through `step_05.gleam:main` start checkpoints on
  ports 8101–8105. The first three select read-only, voting, and timed raw
  behavior; the last two use composed channels.

## Invariants

- `poll.gleam:vote` increments only open polls; `close` is idempotent.
- `store.gleam:leave` removes poll and membership state after the last member.
- `raw.gleam:update` requires joined `poll:<non-empty-room>` topics;
  the selected stage controls voting and closing.
- `channel_handler.gleam:PollInfo` and `GuideInfo` keep private-info messages
  distinct between handlers.

## Side effects

- `store.gleam:start` starts an actor; `get`, `vote`, and `close` use
  synchronous calls with 1,000 ms timeouts.
- `timer.gleam:after` schedules actions. Raw and composed handlers notify
  senders and broadcast poll updates.
- `server.gleam:run` starts supervision and Mist, prints the URL, and sleeps
  indefinitely. `step_05.gleam:main` enables health and guide behavior and limits.

## Verification

From the repository root: `cd examples/live_poll && gleam build`.
For an interactive checkpoint, run `gleam run -m live_poll/step_01` from that
package; substitute `step_02` through `step_05` as needed.
