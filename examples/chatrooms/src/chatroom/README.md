# Chat channel and HTTP handlers

## Overview

The local app module supplies lobby and room handlers. The router supplies the
chat page, static assets, and room-directory API.

## Interface

- `app.gleam:Context` and `handlers` configure the channel handlers.
- `router.gleam:Context` and `handle_request` expose HTTP routing.

## Invariants

- `app.gleam:room` accepts rooms in the public group.
- `app.gleam:max_room_users` sets the tracked room capacity to 20.
- `app.gleam:new_message` rejects empty messages.

## Side effects

- `app.gleam:accept_room`, `typing`, and `on_terminate` change presence and
  publish room/lobby updates. Message handlers broadcast chat events.
- `router.gleam:rooms_api` reads group topics and presence counts.

## Verification

From the repository root: `cd examples/chatrooms && gleam build`.
Browser verification uses `pnpm -C examples/chatrooms test`. The root
`gleam.toml` excludes this package from the workspace test task.
