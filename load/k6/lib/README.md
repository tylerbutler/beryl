# k6 client and helpers

## Overview

The k6 workloads share a Phoenix V2 WebSocket client, validation helpers,
metrics, and result metadata. Configuration/protocol helpers can run under
Node; the client and metric modules require k6.
[phoenix.js:PhoenixClient] [metrics.js:clientMetrics]

## Interface

| Module | Public boundary |
|---|---|
| [Configuration](./config.js) | `DEFAULTS`, `loadConfig(env)`, `buildWebSocketUrl(config)`. [config.js:loadConfig] [config.js:buildWebSocketUrl] |
| [Protocol](./protocol.js) | `ProtocolError`, `RefGenerator`, `BoundedRefTombstones`, `validateFrame`, `encodeFrame`, `decodeFrame`, `decodeReply`. Reference generators expose `next()`; tombstones expose `set`, `get`, `delete`, and `clear`. [protocol.js:RefGenerator] [protocol.js:BoundedRefTombstones] [protocol.js:validateFrame] [protocol.js:decodeReply] |
| [Phoenix client](./phoenix.js) | `PhoenixReplyError`, `PhoenixTimeoutError`, and `PhoenixClient`; client methods are `onMessage`, `onError`, `connect`, `join`, `push`, `leave`, `leaveAll`, `close`, and `shutdown`. [phoenix.js:PhoenixClient] |
| [Profiles](./profile.js) | `PROFILE_NAMES`, `parseProfile(document, expectedName)`, `buildOptions(profile, env)`. [profile.js:parseProfile] [profile.js:buildOptions] |
| [Scenario configuration](./scenario-config.js) | `loadScenarioConfig(profile, env)`, `clientConfigForVu(config, vu)`. [scenario-config.js:loadScenarioConfig] [scenario-config.js:clientConfigForVu] |
| [Workload helpers](./workload.js) | `durationMilliseconds`, `participantId`, `broadcastGroupTopic`, `presenceSnapshotMatches`, `replyContainsMarker`, `isForbiddenReply`, `PendingAcknowledgements`, and `finalizeClient`. [workload.js:durationMilliseconds] [workload.js:participantId] [workload.js:broadcastGroupTopic] [workload.js:presenceSnapshotMatches] [workload.js:replyContainsMarker] [workload.js:isForbiddenReply] [workload.js:PendingAcknowledgements] [workload.js:finalizeClient] |
| [Metrics](./metrics.js) | Named Phoenix `Trend`, `Counter`, and `Rate` instances plus the frozen `clientMetrics` recording facade. The [suite guide](../../README.md#metrics) lists emitted metric names. [metrics.js:clientMetrics] |
| [Results](./results.js) | `resultMetadata(profile, effective, env)`, `summaryPath(profile, env)`, `buildSummary(data, profile, effective, env)`. These construct values; they do not write files. [results.js:resultMetadata] [results.js:summaryPath] [results.js:buildSummary] |

## Invariants

- Configuration requires an absolute `ws://` or `wss://` target without a
  fragment. `WS_PATH` must be empty or begin with `/` without query/fragment.
  URL construction adds `vsn=2.0.0` and rejects another version or malformed
  query encoding. [config.js:targetUrl] [config.js:path]
  [config.js:buildWebSocketUrl]
- Numeric settings use safe integers with setting-specific minima. A nonzero
  heartbeat interval requires a shorter heartbeat timeout.
  [config.js:integer] [config.js:loadConfig]
- Text frames contain five elements with nullable/string/safe-integer refs,
  nonempty topic/event strings, and object payloads. Reply decoding requires
  `phx_reply`, a nonempty status string, and a response property.
  [protocol.js:validateFrame] [protocol.js:decodeFrame]
  [protocol.js:decodeReply]
- Ref generation throws at safe-integer exhaustion. Tombstones have a positive
  size limit and evict oldest entries above that bound.
  [protocol.js:RefGenerator] [protocol.js:BoundedRefTombstones]
- Connect requires an idle/closed client; join/push/leave require an open
  socket. Topics cannot join twice; push requires a joined topic and cannot
  replace lifecycle operations. Replies must match reference, topic, and join
  reference. [phoenix.js:PhoenixClient.connect]
  [phoenix.js:PhoenixClient.join] [phoenix.js:PhoenixClient.push]
  [phoenix.js:PhoenixClient.leave] [phoenix.js:PhoenixClient._handleMessage]
- Profiles accept `constant-vus`, `per-vu-iterations`, or
  `constant-arrival-rate`, a nonempty `exec`, and nonempty threshold arrays.
  `MAX_VUS` cannot be smaller than `PREALLOCATED_VUS`.
  [profile.js:parseProfile] [profile.js:buildOptions]
- Scenario configuration validates all supplied target URLs. VU selection
  cycles through targets using VU number and generator index.
  Mixed HTTP requires `HTTP_TARGET_URL`; expected broadcast recipients must
  be fewer than group size. Idle sessions must cover the profile duration
  and exceed a nonzero heartbeat interval.
  [scenario-config.js:loadScenarioConfig]
  [scenario-config.js:clientConfigForVu]
- `shutdown()` attempts leaves, closes, then propagates a leave failure.
  `finalizeClient()` falls back to close on shutdown failure and returns
  false. [phoenix.js:PhoenixClient.shutdown] [workload.js:finalizeClient]
- Presence delivery defaults to `presence_list`. `presenceSnapshotMatches`
  checks for a session key's presence on join and absence on leave in a
  flat snapshot object. It rejects null, arrays, and non-object payloads.
  [scenario-config.js:loadScenarioConfig] [workload.js:presenceSnapshotMatches]

## Side effects

- `PhoenixClient` opens/sends/closes WebSockets, manages request and heartbeat
  timers, updates lifecycle maps, records metrics, and invokes handlers.
  Without an error handler it logs client errors to the console.
  [phoenix.js:PhoenixClient.connect] [phoenix.js:PhoenixClient._request]
  [phoenix.js:PhoenixClient._observeError]
- Metric construction registers k6 metrics; facade calls emit samples.
  [metrics.js:clientMetrics]
- `RefGenerator` and tombstones mutate local state;
  `PendingAcknowledgements` retains promises until drain. Value-building
  configuration/results helpers perform no network or disk I/O.
  [protocol.js:RefGenerator.next] [protocol.js:BoundedRefTombstones.set]
  [workload.js:PendingAcknowledgements] [results.js:buildSummary]

## Verification

From the repository root, `just load-syntax` parses JavaScript/MJS files
without executing workloads. `just load-helpers` runs local Node checks for
helpers, profiles, rendering, and client lifecycle. Node.js is required.
[justfile:load-syntax] [justfile:load-helpers] [../package.json:scripts]

`just load-check` adds Docker-based inspection with `grafana/k6:2.1.0`;
it may pull the image but does not contact a target. Running workloads
requires k6, a reachable target, and intentional load authorization.
[justfile:load-check] [phoenix.js:PhoenixClient.connect]
