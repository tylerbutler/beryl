# Example helper source

## Overview

The root module is an empty entry point. The Erlang FFI supplies the ETS
operations used by session presence.

## Interface

- `example_helper.gleam:main` returns `Nil`.
- `example_session_presence_ffi.erl:new_store`, `track`, `untrack`, `count`,
  `snapshot`, and `exists` form the local ETS FFI boundary.
- [Helper modules](./example_helper/README.md) expose the usable Gleam utilities.

## Invariants

`example_session_presence_ffi.erl:new_store` creates a public ETS set keyed by
topic/session pairs with read/write concurrency enabled. Its owning process
controls the table lifetime.

## Side effects

`example_session_presence_ffi.erl:new_store`, `track`, and `untrack` create
and mutate ETS state; `count`, `snapshot`, and `exists` inspect it.

## Verification

From the repository root: `cd examples/example_helpers && gleam build`.
