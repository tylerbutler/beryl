# Portable protocol source

## Overview

`beryl_protocol` implements channel lifecycle transitions as immutable data.
A host supplies identity and time, then executes the returned actions. The
module depends on `gleam_stdlib` and `gleam_json`, without BEAM process APIs.

## Interface

- Opaque `Config`, `State`, `Connection`, `Channel`, and `Operation` represent
  limits and lifecycle capabilities (`beryl_protocol.gleam:Config`,
  `beryl_protocol.gleam:State`, `beryl_protocol.gleam:Connection`,
  `beryl_protocol.gleam:Channel`, `beryl_protocol.gleam:Operation`).
- `Decoded`, `Input`, `Outbound`, and `Action` describe normalized frames,
  host completions, logical output, and ordered host work. `CloseMode`,
  `CloseReason`, and `Status` describe lifecycle outcomes
  (`beryl_protocol.gleam:Decoded`, `beryl_protocol.gleam:Input`,
  `beryl_protocol.gleam:Outbound`, `beryl_protocol.gleam:Action`,
  `beryl_protocol.gleam:CloseMode`, `beryl_protocol.gleam:CloseReason`,
  `beryl_protocol.gleam:Status`).
- `config`, `with_limits`, `with_topicless_events`, and `new` construct
  configuration and state. `step` returns the next state and actions
  (`beryl_protocol.gleam:config`, `beryl_protocol.gleam:with_limits`,
  `beryl_protocol.gleam:with_topicless_events`, `beryl_protocol.gleam:new`,
  `beryl_protocol.gleam:step`).
- Validation covers topics, patterns, events, byte limits, and reserved names:
  `validate_topic`, `validate_pattern`, `validate_event`, `valid_topic`,
  `topic_allowed`, `reserved_topic`, `valid_event`, and `event_allowed`
  (`beryl_protocol.gleam:validate_topic`, `beryl_protocol.gleam:validate_pattern`,
  `beryl_protocol.gleam:validate_event`, `beryl_protocol.gleam:valid_topic`,
  `beryl_protocol.gleam:topic_allowed`, `beryl_protocol.gleam:reserved_topic`,
  `beryl_protocol.gleam:valid_event`, `beryl_protocol.gleam:event_allowed`).
- Queries expose `connection`, `close_reason`, `next_deadline`, `channel`,
  `can_join`, `joined_ref`, `instance_ref`, `push_channel`, `topics`,
  `resolve_topic`, `stale_join_ref`, and `can_push`
  (`beryl_protocol.gleam:connection`, `beryl_protocol.gleam:close_reason`,
  `beryl_protocol.gleam:next_deadline`, `beryl_protocol.gleam:channel`,
  `beryl_protocol.gleam:can_join`, `beryl_protocol.gleam:joined_ref`,
  `beryl_protocol.gleam:instance_ref`, `beryl_protocol.gleam:push_channel`,
  `beryl_protocol.gleam:topics`, `beryl_protocol.gleam:resolve_topic`,
  `beryl_protocol.gleam:stale_join_ref`, `beryl_protocol.gleam:can_push`).
- Pending-work queries expose `pending_join`, `join_wire_key`,
  `pending_cleanup`, `pending_count`, `reply_pending`, and `reply_wire_key`
  (`beryl_protocol.gleam:pending_join`, `beryl_protocol.gleam:join_wire_key`,
  `beryl_protocol.gleam:pending_cleanup`, `beryl_protocol.gleam:pending_count`,
  `beryl_protocol.gleam:reply_pending`, `beryl_protocol.gleam:reply_wire_key`).
- `export` and `restore` serialize and validate bounded snapshots. `Error`,
  `ValidationError`, and `describe_error` report failures
  (`beryl_protocol.gleam:export`, `beryl_protocol.gleam:restore`,
  `beryl_protocol.gleam:Error`, `beryl_protocol.gleam:ValidationError`,
  `beryl_protocol.gleam:describe_error`).

## Invariants

- The host supplies a unique connection epoch and explicit time. Execute
  returned actions in list order and complete admission/cleanup barriers before
  advancing their dependent work (`beryl_protocol.gleam:new`,
  `beryl_protocol.gleam:Action`).
- A rejected transition commits no state or actions. Stale capabilities and
  completions are successful no-ops; wire metadata cannot replace opaque
  operation identity (`beryl_protocol.gleam:Error`,
  `beryl_protocol.gleam:Input`, `beryl_protocol.gleam:Operation`).
- `DrainBeforeCleanup` retains committed push/reply work until drain completion.
  `InvalidateImmediately` drops reply capability when closing starts
  (`beryl_protocol.gleam:begin_close`, `beryl_protocol.gleam:can_push`).
- Pending limits count authorizing/admitting joins and deferred replies;
  channel limits bound cleanup barriers (`beryl_protocol.gleam:with_limits`,
  `beryl_protocol.gleam:pending_count`).
- A topicless event resolves only with the flag enabled and one established
  topic (`beryl_protocol.gleam:resolve_topic`).
- Snapshots use version 1 and a 1 MiB ceiling. They omit host callbacks,
  application payloads, and clock-origin timestamps. Restore validates state
  and emits terminal actions for unrecoverable work
  (`beryl_protocol.gleam:export`, `beryl_protocol.gleam:restore`,
  `beryl_protocol.gleam:maximum_snapshot_bytes`).

## Side effects

None. `step` and `restore` return action descriptors; the host performs sends,
callbacks, cleanup, and timer scheduling (`beryl_protocol.gleam:step`,
`beryl_protocol.gleam:restore`, `beryl_protocol.gleam:Action`).

## Verification

From the repository root: `just protocol-test` builds strictly and runs the
protocol cases on Erlang and JavaScript.
