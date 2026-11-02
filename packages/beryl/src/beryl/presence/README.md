# Presence wire encoding

## Overview

Encode beryl presence snapshots and diffs as Phoenix presence JSON. The parent
`beryl/presence` module owns the entries and delivery scope; this module only
formats values.

## Interface

- `encode_diff` produces the `joins` and `leaves` object for a topic
  (`wire.gleam:encode_diff`).
- `encode_state` produces a full presence-state object
  (`wire.gleam:encode_state`).

## Invariants

- Each presence key maps to an object containing a `metas` list. Repeated keys
  retain metadata in input order (`wire.gleam:encode_entries`,
  `wire.gleam:group_metas_by_key`).
- Encoded diffs omit delivery scope. A custom publisher must inspect
  `presence.diff_scope` before choosing local or cluster delivery
  (`wire.gleam:encode_diff`).

## Side effects

None. Both entry points construct JSON values without publishing them
(`wire.gleam:encode_diff`, `wire.gleam:encode_state`).

## Verification

From the repository root: `just test beryl`.
