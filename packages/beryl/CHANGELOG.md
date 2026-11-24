# beryl changelog

## v0.6.2 - 2026-11-23

### Fixed

#### Connection admission fails closed on invalid recovered checkpoints.

beryl refuses admission when a remembered connection checkpoint is deleted,
lacks its state row, or cannot be read. Worker recovery no longer resets live
connection accounting within the same supervisor generation. First startup
and replacement of the whole supervisor subtree still start with fresh state.

#### Lifecycle failures preserve socket isolation.

A blocked or raising socket closer no longer stalls or kills the shared
router. Fatal downstream admission during socket initialization stops later
effects and rejects the socket.

Recovery ticks no longer multiply pending work continuations while the queue
remains busy. Socket lifecycle messages keep their bounded wake schedule.

Old-reference leaves no longer cancel replacement joins awaiting authorization
or admission. A duplicate drain completion cannot replace an already committed
fault with a normal close.

#### Named ETS handles preserve their table instance.

Typed ETS handles retain the original table identity after a named table is
deleted and recreated. Ownership transfers carry that identity in a private
gift envelope while typed selectors expose the original gift. Native consumers
must use the typed selector; legacy name-only transfer messages are rejected
because they cannot identify a table generation.

#### Only table owners can delete ETS tables.

The bundled `beryl_heirloom` API now returns `AccessDenied` when a non-owner
tries to delete a table, including a writer with `Public` access. Public
writers can still insert rows, and the owner retains control of whole-table
deletion.

#### Ownership transfers report recipient death.

Callers now receive `RecipientNotAlive` if the recipient exits after the
liveness check but before ETS transfers ownership. The caller keeps the table
and its configured heir; heir-setting errors remain unchanged.

#### Unchanged presence entries return after retirement.

An unchanged presence entry is restored when the same owner reconnects after
retirement and answers a fresh snapshot request. Causal history and stale-reply
fencing remain intact.

#### Unnamed table labels no longer create atoms.

Creating unnamed `beryl_heirloom` tables validates each label without adding it
to the permanent VM atom table. Services can use distinct labels for scratch
tables without accumulating label atoms. UTF-8 validation and the 255-code-point
limit remain unchanged.

Native `ets:info(Table, name)` now reports `beryl_heirloom` for unnamed tables
instead of the configured label. Use the returned handle to identify a table.
Named tables still convert configured names to atoms and require a fixed,
finite set of names.


### Performance

#### Presence selects only the refs affected by local cleanup and replacement.

Runtime presence replacement, socket-owner cleanup, and `untrack_all` use
local ownership indexes instead of scanning unrelated tracking refs. Public
refs remain independent, and replacement socket owners keep their entries
when an old owner exits. CRDT mutation and read-model publication costs are
unchanged.

## v0.6.1 - 2026-11-20

### Added

#### Socket helpers support optional error replies and reply discards.

Use `socket.reply_error` and `socket.discard_reply` with optional reply
references. Deferred replies keep their existing behavior.

#### Log preview configuration names the grapheme limit.

Use `with_payload_preview_graphemes(graphemes:)` to opt in to log previews.
The `with_payload_preview_bytes(bytes:)` builder is deprecated but keeps
its grapheme-based truncation behavior.

#### Channel handlers can decode typed client commands.

Use `channel.on_decoded_message` to decode client events and payloads into
typed commands. Supply an explicit error callback to handle decode failures.
Both callbacks receive the original optional reply handle.

Channels with unrelated command and error types can share one handler list.
Raw message callbacks remain available.

#### Protocol builders let callers configure individual limits.

Use the focused `beryl_protocol` builders to set topic bytes, event bytes,
channels, pending operations, or heartbeat timeout. Each builder preserves
other settings and prior overrides and uses the same validation as
`with_limits`.


### Changed

#### Group broadcast rejections identify topics for retry.

`BroadcastRejected` now includes `rejected_topic` and `remaining_topics`
from the original group broadcast traversal. Callers can use these fields
to retry only topics not admitted to the router.

#### Portable protocol operations distinguish capability kinds.

`Operation(kind)` distinguishes join, reply, admission, and cleanup
capabilities. Hosts must return each action's handle in a matching input.
Stale handles of the correct kind remain no-ops.

#### The transport origin policy uses the name SameAuthority.

Replace `transport.SameOrigin` with `transport.SameAuthority`.
Host-and-port matching, absent-Origin admission, and explicit allow-list
rules keep their existing behavior.


### Fixed

#### Public presence removal preserves runtime-owned entries.

Calls to `presence.untrack` with runtime-owned refs now return `Ok(Nil)`
without changing the live socket presence.

#### Presence recovers its configured replication scope after registry replacement.

Presence now reacquires the configured replication scope after PubSub
registry replacement. Pass `PubSubConfig` to `presence.with_pubsub`
instead of a running handle.

#### Snapshot decoding keeps unsupported versions distinct from invalid data.

The decoder now reads the snapshot version before decoding its
version-specific layout. Callers can distinguish unsupported versions
from invalid snapshots.

#### Node-local handles reject use on another BEAM node.

beryl now rejects these handles before accessing local state on the
other node.

#### Configuration validation rejects invalid connection and protocol limits.

Negative total and per-IP connection ceilings now return
`NegativeConnectionLimit`; zero remains unlimited. beryl validates
translated protocol limits before building a child specification.
`InvalidProtocolConfig` identifies the rejected limit and value.
Add both variants to exhaustive `ConfigError` matches.

`beryl_protocol.InvalidConfig` now includes a `ConfigLimit` and rejected
value. Update matches from `InvalidConfig` to `InvalidConfig(limit, value)`.


### Removed

#### beryl removes the bridge forwarding API before 1.0.

Replace `beryl/bridge` and its forwarding process API with `socket.notify`
or `channel.notify` when the producer accepts a typed sender or callback.
For Subject-only producers, the application must provide adaptation and
lifecycle handling.

## v0.6.0 - 2026-11-18

### Added

- Add `beryl_protocol`, a pure channel lifecycle core for Erlang and JavaScript with connection-scoped join/reply capabilities, ordered actions, heartbeat deadlines, and versioned snapshot export/restoration that preserves closed-connection reasons. Hosts supply I/O, authorization, and application state; the beryl runtime remains Erlang-only.
- Add `with_connection_queue_limits`, defaulting to 256 items and 8 MiB of accounted payload, including executing work. Each acquire reserves two items. When a connection ceiling or per-IP connection rate is enabled, saturation rejects upgrades with HTTP 429. Preserve connection capacity across cancellations, caller exits, and limiter restarts. Byte accounting is structural, not a total-memory cap.
- Support the fixed Custom telemetry identity for third-party transports; exhaustive TelemetryTransport matches must handle Custom.

### Changed

- Return `Result(Frame, EncodeError)` from outbound codec callbacks and `apply_encode_*` helpers; close/error helpers return `Option(Result(Frame, EncodeError))`. Custom encoders must return `Ok(frame)` or `Error(error)`, and exhaustive `socket.StopReason` matches must handle `EncodingFailed(error)`. Runtime encoding failures close the socket, release pending replies and resources, and stop later effects without rolling back earlier effects. Direct helpers only return the callback result.
- Preserve socket-write error reasons through `transport/server.finish_outbound_write`, which now accepts `Result(Nil, WriteError)` instead of `Bool`. Custom transports must replace `True` with `Ok(Nil)` and `False` with `Error(server.WriteFailed(reason))`. Reasons are logged even with payload logging disabled and must exclude payloads and connection metadata.
- Reject negative burst capacities for enabled rate limits with ConfigError.InvalidRateLimitBurst instead of silently dropping all traffic. Zero bursts still default to the rate; disabled limits still ignore bursts. Add a beryl.InvalidRateLimitBurst(burst) branch to exhaustive matches on beryl.ConfigError.
- Reject partial-byte payloads in Phoenix binary encoders with `PayloadNotByteAligned`. Exhaustive `BinaryEncodeError` matches must handle the new variant.
- Rename app-facing JoinRef and ReplyRef to JoinReference and ReplyReference, and rename socket handle arguments from ref to reference. Update type imports and named constructor arguments; the old names have no compatibility aliases. Phoenix wire and codec ref/join_ref names and runtime behavior are unchanged.
- Return errors instead of timing out on failed presence CRDT clock lookups, and acknowledge failed asynchronous mutations. Failed replacements retain existing entries; socket exit releases reserved cleanup capacity. Match track call errors as `TrackRequestFailed(error)` in `PresenceTrackError`, and handle `TrackInvalidCrdtState` and `UpdateInvalidCrdtState`.
- Return typed errors from group and PubSub operations instead of exiting callers. Handle Results from `group.list_groups` and PubSub startup, join/leave, broadcasts, and subscriber queries; match `GroupCallFailed` and `PubSubError`. PubSub broadcasts and queries return `Error(ScopeRecovering)` during local membership replay; broadcasts remain best-effort and are not buffered or replayed. The scoped broadcast wire format is unchanged.

### Fixed

- Count referenced binary sizes against outbound queue byte limits until the transport finishes writing or the connection closes.
- Avoid collisions with downstream heirloom modules by placing the internal ETS helper in the beryl namespace.
- Keep the socket router responsive to shutdown while it processes large disconnects, and skip later callback effects when broadcast admission fails.
- Clarify the caller-enforced same-scope PubSub payload contract, including distinct fixed scopes for incompatible types and presence replication.
- Clarify typed errors returned by synchronous presence mutations.
- Clean up bridge forwarders when startup times out.
- Correct the core API quick-start example to handle payload conversion failures and consume reply references explicitly.
- Discard reply refs in the default channel message handler and document explicit disposal for handlers that do not reply.
- Emit one invalid-message telemetry outcome for decoded events with invalid topics or event names.
- Emit one socket disconnect telemetry event after actor crashes and forced shutdown drains, with documented lifetime measurements.
- Honor opt-in grapheme-limited text-frame previews in Mist and Ewe decode diagnostics; keep binary previews disabled.
- Include inline sender delivery in the local recipient count for socket broadcasts without emitting a second telemetry event.
- Keep local socket routing active during PubSub recovery, wait for the full beryl subtree to exit before reporting a successful stop, and prevent caught group-call timeouts from retaining monitors or late replies.
- Log routine client rejections at debug level, bound diagnostic fields to 256 UTF-8 bytes, and skip rejection formatting when debug is disabled.
- Name the invalid field in binary push frame UTF-8 errors: join_ref or ref.
- Preserve application-owned OTP Logger configuration across runtime starts and restarts, with independent runtime and transport log thresholds for each socket system.
- Report a callback failure to the client as phx_error instead of phx_close when the channel closes before the failure is processed.
- Preserve channel and topic rate-limit allowances across leave/rejoin and duplicate joins for the life of the socket. Previously joined topics count toward `with_channel_rate_max_keys_per_socket` until disconnect. The default cap is 1000; messages requiring a new bucket after the cap is reached are dropped.
- Prevent late shutdown completion messages from remaining in the caller mailbox after stop returns.
- Drain admitted inbound work before delivering Closed on client disconnect, including frames waiting in the router queue.
- Reclaim blocked socket actors when their admitting router exits.
- Reject rate limits whose token cost rounds to zero during config validation.
- Release connection slots and notify the runtime before forced transport shutdown, including shutdowns that bypass the transport close callback.
- Retain bounded callback stack call sites in crash diagnostics without logging stack argument values.
- Run channel termination cleanup when socket output capacity is full, and report rejected cleanup actions as admission failures.

### Performance

- Reduce decoder overhead when converting dynamic JSON payloads and remove temporary value lists from object depth checks. UTF-8 validation and the 64-level nesting limit are unchanged.

### Security

- Preserve exact Unicode suffixes in prefix wildcard captures so distinct topics cannot share channel parameters.

### Dependencies

- Bundle the beryl_heirloom workspace package for typed ETS ownership; beryl consumers need no separate installation or API migration.
- Restrict `lattice_presence` to `>= 2.0.0 and < 2.1.0` for presence-state compatibility.

## v0.5.0 - 2026-09-24

### Added

- Add channel.on_presence callbacks with an initial topic roster, ordered presence changes, and topic-scoped cleanup and failure handling.
- Add channel.with_presence to track a joined connection, send its Phoenix presence_state snapshot, and reuse automatic presence cleanup.

### Changed

- A join to an unmatched topic is now refused before the runtime starts a worker process.
- Bound local runtime and presence work with finite item and byte limits, callback-result limits, and queue snapshots. Notifications, broadcasts, and presence mutations now return typed errors; handle admission rejection and timeouts that may leave running work.
- Each accepted channel topic now runs in its own supervised process. A slow callback or callback panic affects only that topic. An `on_info` panic closes its topic instead of the socket. beryl does not define an order between different topics on one socket.
- Presence replica identities now use the dependency's incarnation format, a retired incarnation keeps a high-water clock, and a snapshot that claims the local replica identity is dropped with an error log and a telemetry event.
- Make wire.encode return Result(String, Nil). Rename beryl/stats.snapshot to beryl/snapshot.get, JoinContext.params to parameters, socket msg_ref labels to message_ref, reply_ref_msg_ref to reply_ref_message_ref, presence op_id to operation_id, SyncPayload.v to version, and transport AuthRejected/vsn_supported to AuthenticationRejected/version_supported. Document exhaustive public error matching.
- Return group, presence update, and binary encoding errors with the offending name, ref, or metadata component.

### Fixed

- A graceful stop now bounds each worker's on_terminate to fit inside the shutdown drain. A slow on_terminate no longer makes beryl.stop fail or skip the remaining topics' cleanup. Closes outside beryl.stop keep the five-second bound.
- Add explicit ReplyRef discard effects that release socket capacity without sending a reply or expiring deferred replies.
- Apply committed worker reports before closing a topic whose worker has exited.
- Bound crash diagnostic formatting and retained memory for large exception reasons.
- Bound each connection's outbound queue by frames and bytes, and close slow clients before enqueueing beyond the configured budget.
- Clarify that with_max_connections applies independently to each beryl system on each BEAM node.
- Clean runtime-owned presence entries when sockets disconnect or their router exits.
- Contain on_diff callback failures so successful presence mutations and remote merges still publish state and acknowledge while preserving synchronous ordering.
- Correct public API documentation for terminal frames, PubSub startup, presence replication, and log preview limits.
- Corrected documentation examples to follow Gleam naming and exhaustive matching conventions.
- Ensure untrack_all removes and reports only locally owned presence entries.
- Fence stale presence incarnations and compact unavailable replica history safely after 60 seconds using fresh owner-only snapshots.
- Give each reply handle a unique request identity so stale replies cannot consume requests that reuse wire identifiers, including after a topic closes and rejoins.
- Handle read-model publication failures without panicking.
- Hide unavailable presence replicas after actor, node, or membership loss. Keep replica-view diffs node-local while preserving cluster-wide application diffs and causal state for reconnect.
- Make repeated and concurrent PubSub topic joins idempotent per owner process and scope, including multiple handles. Deliver and count each owner once, and remove membership with one leave.
- Preserve abnormal worker startup reasons and distinguish runtime stop acceptance from completion with typed outcomes.
- Reclaim abandoned and timed-out connection reservations.
- Repair quiet presence replication with initial and periodic snapshots. All replicas in a presence scope must use sync version 2.
- Restore live PubSub subscriptions after supervised pg scope restarts, preserve idempotent membership, and report startup or invalid-handle failures instead of silently losing delivery.
- Return to the actor selector between resumed inbox items so sustained work cannot starve shutdown, heartbeats, or monitor messages.
- Scope connection-limit checkpoints to each supervised app incarnation so replacement subtrees cannot inherit or lose admission state from predecessors.
- Stop connection-limit checkpoint heirs when their supervising subtree exits during checkpoint initialization.
- Stop heartbeat-evicted socket actors after lifecycle teardown completes.
- Suppress late connection-limit acquire and bind replies after callers time out or the limiter exits.
- Surface presence read-model deletion failures instead of treating them as successful publication.

### Removed

- The channel API no longer exposes handler pattern introspection, duplicate message topics, socket-wide stops, or raw binary callbacks. Use the join context or channel state for topics. Use raw dispatch for socket-wide control and raw binary frames.

### Dependencies

- Require lattice_presence 2.0, which adds youid as a transitive dependency.
- Use rasa for monotonic clocks instead of beryl-owned Erlang adapters.

## v0.4.1 - 2026-08-25

### Fixed

- Make presence.update honor the configured call timeout.

## v0.4.0 - 2026-08-24

### Changed

- **Channel callback registration now starts from `channel.accept(state)`.** Pipe accepted joins through `channel.on_message`, `channel.on_binary`, `channel.on_info`, and `channel.on_terminate`; replace `channel.next(state, [])` with `channel.stay(state)`.
- Stats snapshots are now documented as eventually consistent: counts are point-in-time values as observed by the runtime process servicing the request and may lag in-flight connect/disconnect notifications.
- Stats snapshots succeed while an app callback is mid-flight, and socket counts are eventually consistent as documented: disconnects are reflected once the router processes the socket actor's teardown notification.
- The runtime now runs one actor per connected socket behind a lightweight router: app init/update callbacks run in the socket's own process, so one socket's slow callback no longer stalls others, and broadcast fan-out encodes per recipient on separate schedulers (benchmarked ~7x faster delivery under fan-out load at 10ms callback cost, with no regression on point-to-point traffic). Public API and wire behavior are unchanged.

### Fixed

- Socket actor crashes now close their transport and sweep runtime-owned presence, and forced shutdowns return StopTimeout.

### Removed

- Broadcast telemetry no longer reports a send_failures measurement: the broadcast origin hands each recipient's frame to that socket's own actor and cannot observe the sends. Per-socket send failures remain visible in logs.
- Stats snapshots no longer report `runtime_mailbox_length`, and `beryl/stats.runtime_mailbox_length` is removed. The metric assumed a single runtime mailbox, a pre-1.0 leak of the runtime process topology.

## v0.3.0 - 2026-08-21

### Added

- Add `beryl/channel`, a supervised, typed API for routing topics to handlers and sending ordered effects and server messages.
- Add `presence.update` to replace one presence entry atomically without briefly removing its key.
- Add per-IP connection-attempt rate limits that persist across reconnects, app runtime restarts, and limiter restarts.
- Add public codec operations for implementing and testing custom codecs.

### Changed

- BREAKING: Replace `beryl.start_app` and `beryl/event` with supervised `beryl.child_spec` and `beryl/socket`. `socket.Next` now carries only the model type, and separate `JoinRef` and `ReplyRef` values prevent join responses and message replies from being mixed.
- BREAKING: `wire.dynamic_to_json` now returns `Result(Json, Nil)` when a value exceeds the wire depth limit instead of replacing it with `null`.
- Beryl now processes presence mutations asynchronously, so a busy presence service does not block unrelated sockets, broadcasts, heartbeats, or shutdown. Reads remain immediately consistent, and Beryl logs timed-out mutations before resuming the waiting socket.
- BREAKING: PubSub messages now include their scope, preventing subscribers from matching messages from another scope in the same mailbox. Nodes using the old and new message formats cannot exchange PubSub broadcasts during a rolling upgrade.
- Phoenix wire decoding now identifies the field with an invalid format instead of returning a generic decoding error.
- BREAKING: `beryl.ConfigError.InvalidTopicPattern` now carries a `beryl/topic.TopicError` instead of a `String`. Match unknown `TopicError` variants with a catch-all unless you handle them separately.
- BREAKING: `with_frame_rate` limits every inbound frame before decoding, while `with_message_rate` limits successfully decoded non-join messages. The limits are independent; configure both to reject malformed-frame floods and cap decoded traffic. Rate-limited heartbeats do not extend socket deadlines.
- Group broadcast calls now apply backpressure to senders under heavy traffic.
- BREAKING: Start presence and groups with supervised child specifications. Handles are node-local: remote presence mutations and group calls panic, remote presence reads return `Error(Nil)`, and remote group broadcasts are not delivered. Configure synchronous call timeouts with `with_call_timeout`; the five-second default is unchanged.
- Presence reads no longer wait on the presence process, and the new `presence.count` returns a topic's entry count. `presence.list`, `presence.get_by_key`, and `presence.count` now return `Result(_, Nil)` when presence is unavailable or a handle is used from another node.
- BREAKING: Runtime snapshots now expose `runtime_mailbox_length` and `RuntimeUnavailable` instead of `coordinator_mailbox_length` and `CoordinatorUnavailable`. Remove uses of the deleted `registered_channel_handlers` gauge.
- BREAKING for transport authors: Use `beryl/transport/server` and `beryl/transport/origin` for shared configuration, origin checks, admission, and routing. Replace `connection_owner` and `ConnectionOwner` with `runtime_pid`, pass an optional codec to `admit_socket`, and use the timeout-only `with_heartbeat`.

### Fixed

- Non-positive `with_topic_rate` overrides now disable rate limiting for matching topics without allocating limiter state. Positive overrides still take precedence over the global channel rate limit.

### Removed

- BREAKING: Remove the v0.2 channel registry API, including `beryl.register`, `beryl.send_info`, and `RegisteredChannel`. Use `beryl.child_spec` for raw dispatch or `beryl/channel` for typed channel handlers.

## v0.2.0 - 2026-08-07

### Added

- New app-side dispatch API (ADR 0002): `beryl.start_app(config, init, update)` with `beryl/event` (`Event`/`Next`/`Effect`, typed `Sender`/`notify`, `ConnectInfo`), per-topic-pattern rate limits via `with_topic_rate`, single-use reply refs with duplicate-outstanding rejection, and the existing socket/channel/broadcast telemetry schema. The channel-module API is unchanged; both run side by side during the migration.

### Changed

- PubSub now uses a typed `Subscriber(payload)` handle that can join or leave many topics while preserving the frozen raw `Message(payload)` record sent between BEAM nodes: replace `pubsub.subscribe`/`pubsub.unsubscribe` with `pubsub.subscriber` plus `join`/`leave`, and pass that subscriber to `pubsub.selecting`, which keeps raw-mailbox recovery inside the library. `beryl/bridge` is decoupled from channels and now forwards to an `event.Sender` via `event.notify` — `bridge.start(to:, with:)` returns a `Result` and no longer takes a RegisteredChannel, socket id, or topic. Distributed broadcast shape and semantics, sender exclusion, and subscriber counts are unchanged.
- Transport SPI: transports capture `connection_owner`, monitor the exact app runtime, then atomically register the socket, closer, and `ConnectSeed` with `transport.admit_socket`; channel-module systems remain unmonitored.

### Fixed

- Preserve binary message classification when transports decode binary frames before routing them to the app runtime.
- Prevent stale same-topic join completions and timed-out admissions from affecting live sockets.
- Recover the app runtime subtree after nested supervisor restart-intensity exhaustion.
- Recover the app supervisor when the runtime crashes during beryl.stop so later stops and restart exhaustion remain correct.

### Removed

- `beryl.start` and `beryl.StartError` are no longer public. Starting a channel system without supervision left a runtime crash unrecoverable and every connected socket stranded, so the API no longer offers it as a choice. Applications build beryl with `beryl.child_spec` and add the returned child specification to their own OTP supervision tree. `beryl.stop` remains available for gracefully stopping an app-dispatch runtime.

## v0.1.0 - 2026-08-07

### Added

- App-side dispatch API: `beryl.start_app(config, init, update)` with `beryl/event` (`Event`/`Next`/`Effect`, typed `Sender`/`notify`, `ConnectInfo`), per-topic-pattern rate limits via `with_topic_rate`, single-use reply refs with duplicate-outstanding rejection, and socket/channel/broadcast telemetry. The channel-module API is unchanged; both can run side by side.
- Initial release: type-safe Phoenix-style real-time channels for Gleam on the BEAM. Channel join/message/info/terminate callbacks with typed assigns and typed server-originated messages (send_info and the beryl/bridge actor forwarder), segment-aware topic pattern matching with wildcards, broadcasts including broadcast_from sender exclusion, Phoenix-compatible error/close reply semantics, named channel groups, and OTP supervision via beryl/supervisor.
- Abuse controls and hardening: heartbeat-based socket eviction, per-socket message/join/channel token-bucket rate limits, per-IP and node-wide connection ceilings, frame-size/topic-length/event-length caps, callback crash isolation, and a startup warning when no controls are configured.
- Structured logging through palabres with configurable level and bounded, opt-in payload previews, plus a public transport SPI (beryl/transport) so WebSocket transports such as beryl_mist can be implemented outside the core package.
- Added `transport.socket_connected_with_codec`, letting a transport announce a socket that frames its outbound messages with its own codec instead of the configured one. One coordinator — sharing channels, pubsub, and presence — can serve transports speaking different wire formats. `socket_connected` is unchanged.
- Phoenix-compatible presence tracking backed by lattice_presence CRDTs: track/untrack with server-minted refs, presence_state and presence_diff wire encoding (including phx_ref metas), and cluster replication over PubSub guarded by an exception boundary.
- pg-based PubSub for multi-node broadcast fan-out and presence replication. `PubSub`/`Message` are generic over a `payload` type — broadcasts travel as native BEAM terms, with no forced JSON encoding — and `pubsub.selecting` lets any gleam_erlang/gleam_otp actor receive them through its own `Selector` without touching raw process messages. The wire shape is frozen per `payload` type across the trusted Erlang cluster boundary.
- Phoenix V2 wire protocol (JSON text framing and the binary subprotocol) as the default codec, plus a pluggable codec API (beryl/wire/codec) for custom text/binary framing with opt-in topicless events and close/error encoders.

### Dependencies

- Update locked Gleam dependencies.
