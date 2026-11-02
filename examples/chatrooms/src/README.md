# Chat server source

## Overview

The executable wires the chat handlers, groups, presence, and Mist transport.

## Interface

- `chatroom.gleam:main` starts the application.
- `chatrooms_ffi.erl:timestamp_ms` supplies millisecond system timestamps.
- [Chat handlers](./chatroom/README.md) own channel callbacks and HTTP routing.

## Invariants

- `chatroom.gleam:main` accepts WebSocket connections with the `beryl-demo` token.
- The child handlers enforce public-room membership and the 20-user cap.

## Side effects

- `chatroom.gleam:main` starts supervision and HTTP/WebSocket services,
  creates the public group and three rooms, and sleeps indefinitely.
- `chatrooms_ffi.erl:timestamp_ms` reads system time.

## Verification

From the repository root: `cd examples/chatrooms && gleam build`.
Workspace tests exclude this example; `pnpm -C examples/chatrooms test`
runs its Playwright suite.
