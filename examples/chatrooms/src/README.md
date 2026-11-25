# Chat server source

## Overview

The executable wires the chat handlers, groups, presence, and Ewe transport.
It also starts an isolated socket system for the Phoenix Channels tutorial.

## Interface

- `chatroom.gleam:main` starts the application.
- `chatrooms_ffi.erl:timestamp_ms` supplies millisecond system timestamps.
- [Chat handlers](./chatroom/README.md) own channel callbacks and HTTP routing.

## Invariants

- `chatroom.gleam:main` requires the `beryl-demo` token at `/socket/websocket`.
- `/phoenix/socket/websocket` serves the public tutorial without changing the
  authenticated endpoint.
- The child handlers enforce public-room membership and the 20-user cap.

## Side effects

- `chatroom.gleam:main` starts supervision and HTTP/WebSocket services,
  creates the public group and three rooms, and sleeps indefinitely.
- `chatrooms_ffi.erl:timestamp_ms` reads system time.

## Verification

From the repository root: `cd examples/chatrooms && gleam build`.
Workspace tests exclude this example; `pnpm -C examples/chatrooms test`
runs its Playwright suite.
