# Showcase server source

## Overview

The entry point assembles channel handlers, example resources, and the shared
HTTP/WebSocket server.

## Interface

- `showcase.gleam:Dependencies`, `handlers`, and `main` expose composition
  and startup.
- `showcase_ffi.erl:timestamp_ms` supplies millisecond system time.
- [Router and channels](./showcase/README.md) define HTTP and per-topic boundaries.

## Invariants

- `showcase.gleam:main` configures frame/message/join rates of 35/30/5 per
  second, cursor topic rate 30, and room/document topic rates 10.
- `showcase.gleam:handlers` composes separate handlers with per-topic state.

## Side effects

`showcase.gleam:main` starts presence, the document store, the broadcast hub,
groups, supervision, and the listener, then sleeps indefinitely.
`showcase_ffi.erl:timestamp_ms` reads system time.

## Verification

From the repository root: `cd examples/showcase && gleam build`.
`gleam test` checks package behavior; `pnpm test` runs Playwright on port 8010.
