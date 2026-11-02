# Portable protocol bridge

## Overview

This JavaScript-targeted Gleam bridge turns `beryl_protocol` transitions into
ordered host actions. The worker owns runtime I/O.

## Interface

- `portable_channels.gleam:Transition`, `Action`, and `HostError` describe the boundary.
- `new_connection`, `receive_text`, `receive_binary`, `join_accepted`,
  `join_rejected`, `reply`, `push`, `cleaned_up`, `expire`, and `disconnect`
  expose lifecycle transitions.
- `snapshot`, `restore`, and `next_deadline` expose recovery and timing.
- [Phoenix adapter](./portable_channels/README.md) delegates wire framing to Roost.
- `portable_channels_ffi.mjs:parse` wraps JavaScript JSON parsing.

## Invariants

- `portable_channels.gleam:new_connection` limits topic/event bytes to 255/64,
  channels to one, and pending operations to 64.
- `portable_channels.gleam:convert` preserves action order and completes local
  admission without a separate subscription index.

## Side effects

The bridge emits actions for the host rather than executing network/storage
I/O (`portable_channels.gleam:Action`). Its FFI delegates payload parsing to
`JSON.parse` (`portable_channels_ffi.mjs:parse`).

## Verification

From the repository root: `pnpm -C examples/portable_channels build`.
The example's `pnpm test` adds JavaScript-target Gleam tests and Vitest.
