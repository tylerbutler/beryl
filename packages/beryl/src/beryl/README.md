# beryl modules

## Overview

Application APIs, transport SPI, and BEAM runtime implementation for beryl.
The package manifest's `internal_modules` list and each declaration's
`@internal` annotation determine the supported API. A `pub` declaration in an
internal module remains an implementation detail.

## Interface

### Application and messaging APIs

- `socket` defines `Input`, `Next`, `Effect`, `StopReason`, opaque
  `JoinReference`/`ReplyReference`, `ConnectSeed`, `ConnectInfo`, and typed
  `Sender`. Use `empty_seed`, `reply_ok`, `notify`, and `queue_snapshot`
  (`socket.gleam:Input`, `socket.gleam:Next`, `socket.gleam:Effect`,
  `socket.gleam:StopReason`, `socket.gleam:JoinReference`,
  `socket.gleam:ReplyReference`, `socket.gleam:ConnectSeed`,
  `socket.gleam:ConnectInfo`, `socket.gleam:Sender`, `socket.gleam:empty_seed`,
  `socket.gleam:reply_ok`, `socket.gleam:notify`, `socket.gleam:queue_snapshot`).
- `channel` provides typed `Handler`, `JoinContext`, `Message`, `Sender`,
  phase-indexed `Action`, `JoinResult`, and `Next`. `handler` and `child_spec`
  register routes; `accept`/`reject` decide joins; `next`/`stay`/`close` decide
  updates. `on_message`, `on_info`, `on_presence`, and `on_terminate` install
  callbacks. Builders attach replies, actions, and presence. Action helpers
  cover pushes, broadcasts, replies/discard, and presence operations
  (`channel.gleam:Handler`, `channel.gleam:JoinContext`, `channel.gleam:Message`,
  `channel.gleam:Sender`, `channel.gleam:Action`, `channel.gleam:JoinResult`,
  `channel.gleam:Next`, `channel.gleam:handler`, `channel.gleam:child_spec`,
  `channel.gleam:accept`, `channel.gleam:reject`, `channel.gleam:next`,
  `channel.gleam:stay`, `channel.gleam:close`, `channel.gleam:on_message`,
  `channel.gleam:on_info`, `channel.gleam:on_presence`,
  `channel.gleam:on_terminate`, `channel.gleam:with_reply`,
  `channel.gleam:with_actions`, `channel.gleam:with_presence`,
  `channel.gleam:push`, `channel.gleam:broadcast`, `channel.gleam:broadcast_from`,
  `channel.gleam:reply_ok`, `channel.gleam:reply_error`,
  `channel.gleam:discard_reply`, `channel.gleam:presence_track`,
  `channel.gleam:presence_untrack`, `channel.gleam:push_presence`,
  `channel.gleam:broadcast_presence`).
- `bridge` forwards typed subject messages to a socket sender. `start`,
  `subject`, `pid`, and `stop` operate on `Bridge`; `StartError` reports startup
  failures (`bridge.gleam:Bridge`, `bridge.gleam:StartError`,
  `bridge.gleam:start`, `bridge.gleam:subject`, `bridge.gleam:pid`,
  `bridge.gleam:stop`).
- `topic` provides `TopicPattern`, `parse_pattern`, `matches`, wildcard/ID
  extraction, segment helpers, and topic/pattern/event validation
  (`topic.gleam:TopicPattern`, `topic.gleam:parse_pattern`, `topic.gleam:matches`,
  `topic.gleam:extract_id`, `topic.gleam:extract_wildcards`,
  `topic.gleam:segments`, `topic.gleam:namespace`, `topic.gleam:from_segments`,
  `topic.gleam:validate`, `topic.gleam:validate_pattern`,
  `topic.gleam:validate_event`, `topic.gleam:TopicError`,
  `topic.gleam:ExtractError`).

### Shared state and observations

- `presence` defines opaque `Presence`, `Config`, `Diff`, and subscriptions,
  plus entries/events, `DiffScope`, and mutation errors. Configuration builders
  select PubSub, queue limits, telemetry, intervals, timeouts, and `on_diff`.
  `child_spec`, `track`, `update`, `untrack`, `untrack_all`, `list`, `get_by_key`,
  `count`, and `queue_snapshot` operate on the handle. Diff construction and
  accessors expose scope, topics, joins, and leaves
  (`presence.gleam:Presence`, `presence.gleam:Config`, `presence.gleam:Diff`,
  `presence.gleam:Subscription`, `presence.gleam:PresenceEntry`,
  `presence.gleam:Event`, `presence.gleam:DiffScope`,
  `presence.gleam:PresenceUpdateError`, `presence.gleam:default_config`,
  `presence.gleam:with_pubsub`, `presence.gleam:with_queue_limits`,
  `presence.gleam:with_telemetry`, `presence.gleam:with_broadcast_interval`,
  `presence.gleam:with_call_timeout`, `presence.gleam:with_on_diff`,
  `presence.gleam:child_spec`, `presence.gleam:track`, `presence.gleam:update`,
  `presence.gleam:untrack`, `presence.gleam:untrack_all`, `presence.gleam:list`,
  `presence.gleam:get_by_key`, `presence.gleam:count`,
  `presence.gleam:queue_snapshot`, `presence.gleam:diff`,
  `presence.gleam:diff_scope`, `presence.gleam:diff_topics`,
  `presence.gleam:diff_joins`, `presence.gleam:diff_leaves`).
- [Presence wire encoding](./presence/README.md) exposes `encode_diff` and
  `encode_state`, including the scope obligation for publishers.
- `pubsub` exposes `PubSub`, `PubSubConfig`, `Message`, `PubSubFrom`,
  `Subscriber`, and `PubSubError`; configuration/startup, join/leave/selecting,
  cluster/local broadcasts, sender exclusion, and subscriber queries
  (`pubsub.gleam:PubSub`, `pubsub.gleam:PubSubConfig`, `pubsub.gleam:Message`,
  `pubsub.gleam:PubSubFrom`, `pubsub.gleam:Subscriber`,
  `pubsub.gleam:PubSubError`, `pubsub.gleam:describe_error`,
  `pubsub.gleam:default_config`, `pubsub.gleam:config_with_scope`,
  `pubsub.gleam:start`, `pubsub.gleam:subscriber`, `pubsub.gleam:join`,
  `pubsub.gleam:leave`, `pubsub.gleam:selecting`, `pubsub.gleam:broadcast`,
  `pubsub.gleam:broadcast_from`, `pubsub.gleam:broadcast_from_socket`,
  `pubsub.gleam:local_broadcast`, `pubsub.gleam:subscribers`,
  `pubsub.gleam:subscriber_count`).
- `group` exposes in-memory `Groups`, configuration, and errors; `child_spec`,
  `child_spec_with_config`, `create`, `delete`, `add`, `remove`, `topics`,
  `list_groups`, and `broadcast` manage named sets of topics
  (`group.gleam:Groups`, `group.gleam:Config`, `group.gleam:GroupError`,
  `group.gleam:BroadcastError`, `group.gleam:default_config`,
  `group.gleam:with_call_timeout`, `group.gleam:child_spec`,
  `group.gleam:child_spec_with_config`, `group.gleam:create`,
  `group.gleam:delete`, `group.gleam:add`, `group.gleam:remove`,
  `group.gleam:topics`, `group.gleam:list_groups`, `group.gleam:broadcast`).
- `snapshot` exposes `Snapshot`, `SnapshotError`, `get`, queue occupancy, and
  count accessors for connected sockets, joined socket-topic pairs, and active
  topics (`snapshot.gleam:Snapshot`, `snapshot.gleam:SnapshotError`,
  `snapshot.gleam:get`, `snapshot.gleam:queue`,
  `snapshot.gleam:connected_sockets`,
  `snapshot.gleam:joined_socket_topic_pairs`, `snapshot.gleam:active_topics`).
- `overload` defines admission/call errors, boundaries, occupancy, and validated
  item/byte limits. `error` defines call/operation/start failures and formatting
  (`overload.gleam:AdmissionError`, `overload.gleam:CallError`,
  `overload.gleam:Boundary`, `overload.gleam:Occupancy`, `overload.gleam:Limits`,
  `overload.gleam:LimitError`, `overload.gleam:limits`,
  `overload.gleam:shared_limits`, `overload.gleam:socket_limits`,
  `overload.gleam:worker_limits`, `overload.gleam:max_items`,
  `overload.gleam:max_bytes`, `overload.gleam:describe`,
  `error.gleam:CallError`, `error.gleam:OperationFailure`,
  `error.gleam:StartFailure`, `error.gleam:describe_operation_failure`,
  `error.gleam:describe_call_error`, `error.gleam:describe_start_failure`,
  `error.gleam:from_actor_start_error`).

### Transport and encoding

- `transport` exposes connection permits, acquisition/binding/release,
  `runtime_pid`, `admit_socket`, disconnect notification, codec access,
  decoded/raw frame routing, and transport telemetry
  (`transport.gleam:ConnectionPermit`, `transport.gleam:acquire_connection_slot`,
  `transport.gleam:bind_connection_slot`, `transport.gleam:release_connection_slot`,
  `transport.gleam:runtime_pid`, `transport.gleam:admit_socket`,
  `transport.gleam:socket_disconnected`, `transport.gleam:active_codec`,
  `transport.gleam:route_decoded`, `transport.gleam:route_decoded_binary`,
  `transport.gleam:route_binary`, `transport.gleam:telemetry`,
  `transport.gleam:telemetry_start`, `transport.gleam:telemetry_upgrade_stop`,
  `transport.gleam:telemetry_frame_stop`,
  `transport.gleam:max_inbound_frame_bytes`).
- [Transport server support](./transport/README.md) adds `OriginPolicy`,
  `TransportConfig`, shared upgrade/HTTP selection, and connection/frame
  lifecycle helpers.
- `wire` exposes `phoenix_codec`, text/binary decoders, dynamic JSON conversion,
  text reply/push/close/error/heartbeat encoders, V2 binary encoders, and
  `BinaryEncodeError` (`wire.gleam:phoenix_codec`, `wire.gleam:decode_message`,
  `wire.gleam:decode_binary_message`, `wire.gleam:encode`,
  `wire.gleam:dynamic_to_json`, `wire.gleam:reply_json`, `wire.gleam:push`,
  `wire.gleam:channel_close`, `wire.gleam:channel_error`,
  `wire.gleam:heartbeat_reply`, `wire.gleam:binary_push`,
  `wire.gleam:binary_reply`, `wire.gleam:binary_broadcast`,
  `wire.gleam:BinaryEncodeError`, `wire.gleam:format_decode_error`).
- [Codec interface](./wire/README.md) defines opaque `Codec` and `Inbound`,
  normalized frame types, builders, and callback application.

### Internal implementation boundaries

- `runtime` runs the router, socket actors, topic workers, and protocol action
  interpreter. `app_supervisor` coordinates draining and supervision
  (`runtime.gleam:start_named`, `runtime.gleam:start_socket_actor`,
  `runtime.gleam:WorkerOpener`, `app_supervisor.gleam:start`).
- `connection_limit` owns monitored permits and restart checkpoints;
  `atomic_token` provides one-shot admission state; `outbound_budget` reserves
  frame/byte capacity (`connection_limit.gleam:acquire_optional`,
  `connection_limit.gleam:bind_holder`, `atomic_token.gleam:claim_if_owner_alive`,
  `outbound_budget.gleam:reserve_and_send`).
- `work_queue` wraps native bounded queues; `pubsub_membership` and
  `pubsub_native` reconcile local membership and pg readiness
  (`work_queue.gleam:publish`, `pubsub_membership.gleam:replay`,
  `pubsub_native.gleam:publish_readiness`).
- `rate_limit` supplies caller-owned token buckets. `internal`, `log`, and
  `telemetry` provide callback rescue, bounded diagnostics, and instrumentation
  (`rate_limit.gleam:take`, `internal.gleam:rescue`, `log.gleam:field`,
  `telemetry.gleam:execute`).

## Invariants

- Return exact join/reply capability values. A reply is single-use and belongs
  to its originating topic instance (`socket.gleam:JoinReference`,
  `socket.gleam:ReplyReference`, `runtime.gleam:register_reply_reference`).
- Effects run in list order. Presence mutations suspend that socket's remaining
  effects until resolution. Topic workers preserve per-topic order; cross-topic
  order has no guarantee (`runtime.gleam:run_effects`,
  `runtime.gleam:WorkerOpener`).
- Handler patterns permit overlap; the first match wins. Exact duplicate
  patterns fail validation. Closing-phase channel actions cannot push, reply,
  or track presence (`channel.gleam:compile`, `channel.gleam:check_duplicates`,
  `channel.gleam:select`, `channel.gleam:Action`).
- Successful `notify` means admission, not callback completion. Queue
  reservations remain charged after dequeue until release. Closing admission
  preserves already-reserved work for draining (`socket.gleam:notify`,
  `channel.gleam:notify`, `work_queue.gleam:publish`, `work_queue.gleam:close`).
- Presence handles are node-affine. `lattice_presence` owns the CRDT; beryl owns
  actor integration and per-topic ETS snapshots. `on_diff` runs before snapshot
  publication and cannot veto the mutation (`presence.gleam:Presence`,
  `presence.gleam:State`, `presence.gleam:publish_topic`,
  `presence.gleam:with_on_diff`).
- Presence `Cluster` diffs allow cluster delivery; `LocalNode` diffs must remain
  local. Public session cleanup removes local entries, not replicated entries
  (`presence.gleam:DiffScope`, `presence.gleam:untrack_all`).
- PubSub's raw wire tuple is `(scope, topic, event, payload, from)`. A scope
  requires compatible payload representations across participants. Configure
  scopes with bounded static names because Erlang atoms are not collected
  (`pubsub.gleam:send_to_pid`, `pubsub.gleam:start`,
  `pubsub.gleam:config_with_scope`).
- Membership recovery replays live owners' intent before publishing readiness.
  Failed/timed-out membership mutations may already have recorded intent
  (`pubsub_membership.gleam:replay`, `pubsub_membership.gleam:join`).
- Connection permits follow the monitored owner. Checkpoints survive limiter
  worker restart, not enclosing-supervisor or node shutdown
  (`connection_limit.gleam:bind_holder`).
- Group state resets on actor restart. Group broadcast may admit earlier
  topics before a later rejection; it is not transactional
  (`group.gleam:default_config`, `group.gleam:broadcast_to_topics`).
- Phoenix text uses `[join_ref, ref, topic, event, payload]` and a JSON depth
  limit of 64. Binary decode accepts V2 client push frames; binary encoding
  requires byte-aligned payloads and metadata components of at most 255 bytes
  (`wire.gleam:decode_message`, `wire.gleam:encode`,
  `wire.gleam:decode_binary_message`, `wire.gleam:binary_push`,
  `wire.gleam:binary_reply`, `wire.gleam:binary_broadcast`).

## Side effects

- Runtime startup creates actors, queues, monitors, and timers. It invokes
  application callbacks, interprets returned effects, sends encoded frames,
  and drains or closes resources during teardown
  (`runtime.gleam:start_named`, `runtime.gleam:start_socket_actor`,
  `runtime.gleam:execute_socket_update`, `runtime.gleam:send_frame`,
  `runtime.gleam:begin_router_stop`).
- Presence mutates its CRDT through `lattice_presence`, publishes ETS snapshots,
  invokes diff callbacks, and sends observer/replication messages. Subscription
  handling monitors owners (`presence.gleam:do_track`,
  `presence.gleam:publish_topic`, `presence.gleam:invoke_on_diff`,
  `presence.gleam:register_observer`, `presence.gleam:monitor_runtime_owner`).
- PubSub starts supervised scopes, updates pg membership, and sends raw process
  messages locally or across nodes (`pubsub.gleam:start`, `pubsub.gleam:join`,
  `pubsub.gleam:broadcast`, `pubsub_native.gleam:send`).
- Bridge startup spawns a forwarding process and monitors its owner; callers
  must stop it when the topic/socket ends (`bridge.gleam:start`,
  `bridge.gleam:forward_loop`, `bridge.gleam:stop`).
- Native queue/budget/limiter operations mutate ETS or atomic state. Diagnostics
  use palabres and telemetry FFI; host OTP Logger configuration stays host-owned
  (`work_queue.gleam:publish`, `outbound_budget.gleam:reserve_and_send`,
  `connection_limit.gleam:handle_message`, `log.gleam:emit`,
  `telemetry.gleam:execute`).
- Topic and Phoenix encoders construct values without network I/O; transports
  perform writes. A codec's supplied callbacks can have their own effects
  (`topic.gleam:matches`, `wire.gleam:phoenix_codec`,
  `wire/codec.gleam:apply_encode_reply`).

## Verification

From the repository root: `just test beryl` includes the core serial and
distributed lanes. Use `just protocol-test` for both targets of the imported
protocol core and `just beam-check` for Erlang FFI boundaries.
