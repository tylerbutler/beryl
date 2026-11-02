# Shared example helpers

## Overview

The `example_helper` Erlang package supplies example-only presence, publishing,
payload, color, and HTTP utilities. It is not a released beryl package.

## Subdirectories and boundaries

- [Source](./src/README.md): Gleam helpers and local ETS FFI.

## Interface

`gleam.toml:name` identifies `example_helper`.
`src/example_helper/session_presence.gleam:Tracker` and
`broadcast_hub.gleam:Hub` expose opaque handles. The source contract lists
the payload, color, and static-response functions.

## Invariants

- `src/example_helper/session_presence.gleam:track_if_below` serializes
  capped-room admission and monitors session owners.
- `src/example_session_presence_ffi.erl:new_store` creates an ETS set keyed
  by topic/session pairs.
- `src/example_helper/static.gleam:match_prefix` compares whole path segments.

## Side effects

The helpers start actors, monitor processes, change ETS state, broadcast
rosters, log failures, and send files. Consumers own their app listeners.

## Verification

From the repository root: `cd examples/example_helpers && gleam build`.
The manifest declares `gleeunit`; the root workspace test exclusions do not
exclude this package.
