# beryl packages

## Overview

The workspace separates portable channel lifecycle transitions, the BEAM
runtime, and WebSocket adapters. Package manifests define dependency ownership;
the root workspace controls release bundling and test tasks.

## Interface

- [beryl_protocol](./beryl_protocol/README.md): immutable protocol state,
  capabilities, validation, snapshots, and ordered host actions
  (`beryl_protocol/src/beryl_protocol.gleam:step`,
  `beryl_protocol/src/beryl_protocol.gleam:export`,
  `beryl_protocol/src/beryl_protocol.gleam:restore`).
- [beryl](./beryl/README.md): typed socket/channel dispatch, supervision,
  presence, PubSub, topic groups, Phoenix codecs, and the transport SPI
  (`beryl/src/beryl.gleam:child_spec`, `beryl/src/beryl/channel.gleam:child_spec`,
  `beryl/src/beryl/presence.gleam:child_spec`,
  `beryl/src/beryl/pubsub.gleam:start`, `beryl/src/beryl/transport.gleam:admit_socket`).
- [beryl_mist](./beryl_mist/README.md): Mist `upgrade` and combined HTTP/socket
  `handler` (`beryl_mist/src/beryl_mist.gleam:upgrade`,
  `beryl_mist/src/beryl_mist.gleam:handler`).
- [beryl_ewe](./beryl_ewe/README.md): Ewe `upgrade` and combined HTTP/socket
  `handler` (`beryl_ewe/src/beryl_ewe.gleam:upgrade`,
  `beryl_ewe/src/beryl_ewe.gleam:handler`).

## Invariants

- beryl depends on `beryl_protocol`; adapters depend on beryl and use its shared
  transport server. The protocol package has no BEAM process dependency
  (`beryl/gleam.toml:dependencies`, `beryl_protocol/gleam.toml:dependencies`,
  `beryl_mist/gleam.toml:dependencies`, `beryl_ewe/gleam.toml:dependencies`).
- Manifest `internal_modules` and declaration `@internal` annotations separate
  implementation helpers from supported API (`beryl/gleam.toml:internal_modules`,
  `beryl/src/beryl.gleam:app_dispatch`).
- beryl, Mist, and Ewe target Erlang; the portable protocol supports both
  targets. The workspace bundles the protocol into beryl releases
  (`beryl/gleam.toml:target`, `beryl_mist/gleam.toml:target`,
  `beryl_ewe/gleam.toml:target`, `/gleam.toml:tools.trellis.publish.bundle`).
- Hosts execute protocol actions in order; runtime join/reply capabilities
  cannot be replaced with reconstructed wire metadata
  (`beryl_protocol/src/beryl_protocol.gleam:Action`,
  `beryl/src/beryl/socket.gleam:JoinReference`,
  `beryl/src/beryl/socket.gleam:ReplyReference`).

## Side effects

- The protocol package returns data without I/O
  (`beryl_protocol/src/beryl_protocol.gleam:step`).
- Starting beryl creates supervised processes and ETS-backed queues; configured
  presence and PubSub integrate shared state and inter-node messaging
  (`beryl/src/beryl.gleam:child_spec_supervisor`,
  `beryl/src/beryl_work_queue_ffi.erl:new`,
  `beryl/src/beryl/presence.gleam:do_track`,
  `beryl/src/beryl/pubsub.gleam:broadcast`).
- Adapters own WebSocket writes and force-close operations while shared beryl
  server code owns admission and cleanup
  (`beryl_mist/src/beryl_mist.gleam:on_message`,
  `beryl_mist/src/beryl_mist.gleam:force_close`,
  `beryl_ewe/src/beryl_ewe.gleam:on_message`,
  `beryl_ewe/src/beryl_ewe.gleam:force_close`,
  `beryl/src/beryl/transport/server.gleam:init_connection`).

## Verification

Run commands from the repository root:

- `just test` runs workspace tests, including beryl serial and distributed lanes.
- `just test beryl`, `just test beryl_mist`, or `just test beryl_ewe` scopes the
  package test recipe.
- `just protocol-test` builds strictly and tests the protocol on Erlang and
  JavaScript.
- `just beam-check` checks Erlang FFI through Dialyzer and Xref.
