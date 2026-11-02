# beryl_protocol

## Overview

Portable channel lifecycle state machine for beryl. The host supplies connection
identity, time, decoded input, and completion messages. The protocol returns
immutable state and ordered actions (`src/beryl_protocol.gleam:new`,
`src/beryl_protocol.gleam:step`).

The package depends on `gleam_stdlib` and `gleam_json` and supports Erlang and
JavaScript. The workspace bundles it with beryl rather than releasing it as a
separate package (`gleam.toml:dependencies`,
`/gleam.toml:tools.trellis.publish.bundle`,
`/gleam.toml:tools.trellis.publish.lifecycle`).

## Interface

- `config`, limit/topicless builders, and `new` construct opaque `Config` and
  `State`. `step` maps typed `Input` to next state and `Action` values
  (`src/beryl_protocol.gleam:config`, `src/beryl_protocol.gleam:with_limits`,
  `src/beryl_protocol.gleam:with_topicless_events`,
  `src/beryl_protocol.gleam:new`, `src/beryl_protocol.gleam:step`).
- Validation, channel/capability queries, and pending-work queries support host
  integration (`src/beryl_protocol.gleam:validate_topic`,
  `src/beryl_protocol.gleam:channel`, `src/beryl_protocol.gleam:pending_join`,
  `src/beryl_protocol.gleam:reply_pending`).
- `export`/`restore` provide bounded versioned snapshots
  (`src/beryl_protocol.gleam:export`, `src/beryl_protocol.gleam:restore`).
- [Source contract](./src/README.protocol.md) lists the protocol types, queries,
  errors, and host obligations.

## Invariants

- Hosts issue unique connection epochs, execute actions in order, and complete
  admission/cleanup barriers. Opaque operation capabilities identify completions;
  stale completions are successful no-ops
  (`src/beryl_protocol.gleam:new`, `src/beryl_protocol.gleam:Action`,
  `src/beryl_protocol.gleam:Operation`, `src/beryl_protocol.gleam:Input`).
- Failed transitions commit no state or actions
  (`src/beryl_protocol.gleam:Error`, `src/beryl_protocol.gleam:step`).
- Snapshot version 1 has a 1 MiB ceiling and excludes application payloads and
  host resources (`src/beryl_protocol.gleam:export`,
  `src/beryl_protocol.gleam:maximum_snapshot_bytes`).

## Side effects

None. Hosts execute the action descriptors, including sends, callbacks,
cleanup, and timer scheduling (`src/beryl_protocol.gleam:Action`,
`src/beryl_protocol.gleam:step`, `src/beryl_protocol.gleam:restore`).

## Verification

From the repository root: `just protocol-test` builds strictly and tests both
Erlang and JavaScript.
