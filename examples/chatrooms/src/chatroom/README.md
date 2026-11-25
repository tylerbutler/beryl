# Chat channel and HTTP handlers

## Overview

The local app module supplies lobby and room handlers. The router supplies the
chat page, static assets, and room-directory API.
The separate tutorial handler implements the official Phoenix guide's public
`room:lobby` chat; it does not share the multi-room app's state.

## Interface

- `app.gleam:Context` and `handlers` configure the channel handlers.
- `router.gleam:Context` and `handle_request` expose HTTP routing.
- `phoenix_tutorial.gleam:room` supplies the tutorial's `room:*` handler.

## Invariants

- `app.gleam:room` accepts rooms in the public group.
- `app.gleam:max_room_users` sets the tracked room capacity to 20.
- `app.gleam:new_message` rejects empty messages.
- `phoenix_tutorial.gleam:room` accepts `room:lobby`, rejects other rooms as
  unauthorized, and broadcasts string `body` values without trimming them.

## Side effects

- `app.gleam:accept_room`, `typing`, and `on_terminate` change presence and
  publish room/lobby updates. Message handlers broadcast chat events.
- `router.gleam:rooms_api` reads group topics and presence counts.

## Verification

From the repository root: `cd examples/chatrooms && gleam build`.
Browser verification uses `pnpm -C examples/chatrooms test`. The root
`gleam.toml` excludes this package from the workspace test task.
