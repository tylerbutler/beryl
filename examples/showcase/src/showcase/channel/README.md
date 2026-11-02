# Showcase channels

## Overview

These handlers compose cursor, document, and chat behavior on one beryl socket.
The package imports shared helpers and standalone example modules through the
path dependencies in `examples/showcase/gleam.toml`.

## Interface

- `cursor.gleam:Context` and `channel` expose the cursor handler.
- `document.gleam:Context` and `channel` expose the document handler.
- `room.gleam:Context` and `channel` expose the room handler.

## Invariants

- `cursor.gleam:channel` accepts supported reactions with coordinates in
  the inclusive range 0–1.
- `document.gleam:channel` requires the tenant/document topic shape and a
  tenant-signed token; document state updates have a 65,536-byte limit.
- `room.gleam:channel` admits public-group rooms below the atomic
  20-user presence cap.

## Side effects

- `cursor.gleam:channel` tracks presence and broadcasts cursor/reaction events.
- `document.gleam:channel` reads and merges document-store state, broadcasts
  updates, and logs store timeouts.
- `room.gleam:channel` changes presence, broadcasts messages, and sends lobby
  announcements through the broadcast hub. Its timestamp FFI reads system time.

## Verification

From the repository root: `cd examples/showcase && gleam build`.
Package behavior tests use `gleam test`; browser tests use `pnpm test`.
