# Cursor app and router

## Overview

The app implements per-topic cursor state and a socket-wide raw-dispatch
adapter. The router serves the page, static files, health, and user counts.

## Interface

- `app.gleam:Model`, `Context`, `Note`, `join`, `update`, and `closed`
  expose topic behavior.
- `app.gleam:CursorRooms`, `cursor_rooms_init`, and `cursor_rooms_update`
  expose the raw-dispatch adapter.
- `router.gleam:Context` and `handle_request` expose HTTP routing.

## Invariants

- `app.gleam:cursor_rooms_update` accepts `cursor:*` joins and stores a model
  for each joined topic.
- `app.gleam:decode_reaction` and `coordinate_in_range` require supported
  reactions with coordinates in the inclusive range 0–1.

## Side effects

- `app.gleam:join` and `closed` track and untrack session presence.
- `app.gleam:update` broadcasts cursor movement and valid reactions;
  roster notifications publish presence snapshots.

## Verification

From the repository root: `cd examples/cursors && gleam build`.
Browser tests use `pnpm -C examples/cursors test`. The root `gleam.toml`
excludes this package from the workspace test task.
