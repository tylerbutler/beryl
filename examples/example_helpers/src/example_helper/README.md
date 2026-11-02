# Shared example utilities

## Overview

These example-only utilities provide broadcast publishing, session presence,
payload accessors, colors, and static HTTP responses.

## Interface

- `broadcast_hub.gleam:Hub`, `start`, `bind`, and `publish` expose an opaque
  publisher handle.
- `color.gleam:pastel_for` derives a user color.
- `payload.gleam:string_field`, `string_or`, `float_field`, and
  `json_number_or_zero` decode or relay payload fields.
- `session_presence.gleam:Tracker`, `TrackError`, `start`, `configure`, `stop`,
  `is_running`, `track`, `track_without_publish`, `track_if_below`, `publish`,
  `untrack`, and `count` expose session tracking.
- `static.gleam:serve_static`, `html_response`, `json_response`, `not_found`,
  `drop_leading_slashes`, `match_prefix`, `mime_type_for`, and `priv_static`
  supply HTTP/static helpers.

## Invariants

- `payload.gleam:string_field` and `float_field` return `Error(Nil)` for
  absent or wrongly typed values. The fallback accessors use defaults.
- `session_presence.gleam:track_if_below` serializes count-and-insert admission;
  tracking monitors session owners and removes old monitors on replacement.
- `static.gleam:serve_static` handles GET requests with matching path prefixes;
  `match_prefix` compares whole path segments.

## Side effects

- `broadcast_hub.gleam:start`, `bind`, and `publish` start an actor and enqueue
  work; rejected broadcasts and publishing before binding produce logs.
- `session_presence.gleam:start` creates processes and ETS state; tracking
  changes that state and broadcasts rosters. `stop` releases the store.
- `static.gleam:serve_static` sends files; `priv_static` resolves an OTP
  application private directory.

## Verification

From the repository root: `cd examples/example_helpers && gleam build`.
The package declares `gleeunit` as a development dependency.
