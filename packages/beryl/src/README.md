# beryl source

## Overview

The `beryl` entry module builds typed application dispatch and supervision.
Native Erlang modules implement process calls, ETS queues/read models, pg
integration, and telemetry. The internal `beryl/heirloom` module wraps ETS ownership.

## Interface

- `beryl.Config`, `LoggingConfig`, and `Sockets` are opaque. Construct them with
  `config(codec)`, `logging_config`, and `child_spec`; `LogLevel` selects
  diagnostic severity (`beryl.gleam:Config`, `beryl.gleam:LoggingConfig`,
  `beryl.gleam:Sockets`, `beryl.gleam:config`, `beryl.gleam:logging_config`,
  `beryl.gleam:child_spec`, `beryl.gleam:LogLevel`).
- Configuration builders cover router/socket/worker/effect queues, PubSub,
  presence, telemetry/logging, heartbeat, connection limits, frame/message/
  join/channel rates, topic rules, and frame/topic/event sizes
  (`beryl.gleam:with_router_queue_limits`, `beryl.gleam:with_socket_queue_limits`,
  `beryl.gleam:with_worker_queue_limits`, `beryl.gleam:with_effect_limits`,
  `beryl.gleam:with_pubsub`, `beryl.gleam:with_presence_handle`,
  `beryl.gleam:with_telemetry`, `beryl.gleam:with_logging`,
  `beryl.gleam:with_payload_preview_bytes`, `beryl.gleam:with_heartbeat`,
  `beryl.gleam:with_max_connections_per_ip`,
  `beryl.gleam:with_connection_rate_per_ip`, `beryl.gleam:with_max_connections`,
  `beryl.gleam:with_frame_rate`, `beryl.gleam:with_message_rate`,
  `beryl.gleam:with_join_rate`, `beryl.gleam:with_channel_rate`,
  `beryl.gleam:with_topic_rate`,
  `beryl.gleam:with_channel_rate_max_keys_per_socket`,
  `beryl.gleam:with_max_topic_length`, `beryl.gleam:with_max_event_length`,
  `beryl.gleam:with_max_inbound_frame_bytes`,
  `beryl.gleam:with_max_joined_topics_per_socket`).
- `validate_config` returns `ConfigError`; `stop` returns `StopError`.
  `broadcast`, `broadcast_from`, and `broadcast_presence_diff` submit
  application-level fan-out (`beryl.gleam:validate_config`,
  `beryl.gleam:ConfigError`, `beryl.gleam:stop`, `beryl.gleam:StopError`,
  `beryl.gleam:broadcast`, `beryl.gleam:broadcast_from`,
  `beryl.gleam:broadcast_presence_diff`).
- [Module contracts](./beryl/README.md) cover raw socket and channel APIs,
  presence, PubSub, groups, snapshots, transport support, and wire encoding.
- Native exports and `@internal` entry-module dispatch helpers are package
  implementation details. `beryl/heirloom` also appears in the manifest's
  `internal_modules` list (`beryl.gleam:app_dispatch`,
  `beryl/heirloom.gleam:Table`, `../gleam.toml:internal_modules`).

## Invariants

- A codec is required. Configuration validation requires heartbeat timeout
  at least 2, rates at most 1,000,000,000, and valid topic-rate patterns.
  Non-positive rates mean unlimited; the first matching topic rule wins
  (`beryl.gleam:config`, `beryl.gleam:validate_config`,
  `beryl.gleam:with_topic_rate`).
- `child_spec` builds a specification; a supervisor starts it. Name-backed
  handles survive runtime restarts. The factory starts before the runtime,
  so shutdown drains the runtime first (`beryl.gleam:build_app_subtree`,
  `beryl.gleam:child_spec_supervisor`).
- Socket admission reserves queue capacity before spawning. Rejection or
  failed/timed-out admission releases the reservation and stops the child
  (`beryl.gleam:reserve_socket_start`, `beryl.gleam:finish_socket_admission`).
- Reply-alias calls capture a PID and monitor it. Timeout/owner-down failures
  remain distinct (`beryl_ffi.erl:pin_subject`, `beryl_ffi.erl:actor_call`,
  `beryl_ffi.erl:connection_limit_call`).
- The presence read model stores one protected ETS row per topic as
  `{Topic, Count, Entries}`. An absent topic differs from an unavailable table
  (`beryl_presence_read_ffi.erl:new_table`,
  `beryl_presence_read_ffi.erl:get_topic`).
- Presence-state FFI requires the six-field tuple representation supplied by
  the presence dependency (`beryl_presence_state_ffi.erl:remove_tag`,
  `beryl_presence_state_ffi.erl:owner_snapshot`).
- Native PubSub queries check registry and pg generation around the lookup.
  Scope supervision starts memberships before pg with `rest_for_one`
  (`beryl_pubsub_ffi.erl:query_members`, `beryl_pubsub_supervisor.erl:init`).
- Queue capacity accounts for items and structural bytes; reservations survive
  dequeue until release, and recovery reclaims dead producers' reservations
  (`beryl_work_queue_ffi.erl:retain`, `beryl_work_queue_ffi.erl:recover`,
  `beryl_work_queue_ffi.erl:payload_bytes`).
- `beryl/heirloom` key/value types provide compile-time tracking only. Ownership
  changes require the caller to own the table and recipients/heirs to be live
  local processes (`beryl/heirloom.gleam:Table`, `beryl_heirloom_ffi.erl:ownership_precheck`,
  `beryl_heirloom_ffi.erl:valid_local_process`, `beryl_heirloom_ffi.erl:give_away`).

## Side effects

- Building the child specification allocates names and may warn about disabled
  abuse controls. Starting it creates the supervised runtime, factory, and
  optional limiter. `stop` drains sockets and closes transports; it does not
  stop the separately owned presence process (`beryl.gleam:child_spec`,
  `beryl.gleam:build_app_subtree`, `beryl.gleam:child_spec_supervisor`,
  `beryl.gleam:stop`).
- Native calls send messages, monitor processes, update checkpoint
  `persistent_term` entries, and stop supervisors (`beryl_ffi.erl:actor_call`,
  `beryl_ffi.erl:connection_limit_checkpoint_registry_put`,
  `beryl_ffi.erl:stop_supervisor`).
- Presence and queue helpers mutate ETS; queue operations may invoke wake/
  cleanup callbacks (`beryl_presence_read_ffi.erl:put_topic`,
  `beryl_work_queue_ffi.erl:update`, `beryl_work_queue_ffi.erl:finish`).
- PubSub helpers start scope processes and update pg/readiness state
  (`beryl_pubsub_supervisor.erl:start_scope`, `beryl_pubsub_ffi.erl:try_pg_join`,
  `beryl_pubsub_ffi.erl:publish_readiness`).
- Telemetry FFI emits events and reads mailbox length; error FFI only formats
  bounded diagnostic text (`beryl_telemetry_ffi.erl:execute`,
  `beryl_telemetry_ffi.erl:mailbox_length`,
  `beryl_error_ffi.erl:describe_operation_failure`).
- `beryl/heirloom` creates/mutates/deletes ETS tables, configures heirs, transfers
  ownership, and converts table names to atoms (`beryl_heirloom_ffi.erl:create`,
  `beryl_heirloom_ffi.erl:insert`, `beryl_heirloom_ffi.erl:delete`,
  `beryl_heirloom_ffi.erl:set_heir`, `beryl_heirloom_ffi.erl:give_away`,
  `beryl_heirloom_ffi.erl:table_name`).

## Verification

From the repository root: `just test beryl`, `just protocol-test`, and
`just beam-check`. The core test recipe includes serial and distributed lanes;
the protocol recipe covers Erlang and JavaScript.
