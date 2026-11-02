# README contract drift report

Reviewed 70 README contracts against local production source, manifests, and
verification commands. Found 14 discrepancies across six documents; 64 documents
have no detected drift. Findings include preserved README content as well as
new contract sections.

## Resolution

All 14 findings below are resolved. The original findings and line references
remain as a record of the pre-fix review.

- Root README: handle the JSON conversion result in the quick start, correct
  the example descriptions, and separate pre-upgrade connection admission from
  post-assembly message limits.
- Chat README: describe the unauthenticated HTTP page, actual `phx_reply`
  responses, channel broadcasts, group membership checks, and topic parameters.
- Document README: describe the `document:*` handler and suffix validation.
- Benchmark README: use the mise toolchain, describe synchronous tracker
  mutations, remove the absent statistics field, and document admission rejection.
- Load suite: validate flat `presence_list` snapshots, update the profile,
  configuration default, metadata example, helper tests, and contracts.
  Correct the CI toolchain description.
- Transport contract: document `with_outbound_limits` validation and its
  `OutboundConfigError` result.
- Packaging: name the protocol source contract `README.protocol.md` to avoid
  colliding with beryl's `src/README.md` when trellis bundles the packages.

Validation passed:

- `just load-syntax load-helpers`, including the snapshot regression cases.
- A warnings-as-errors build of the exact corrected root quick-start snippet
  in the benchmark package. The temporary source module was removed.
- Local presence-churn runs against Mist and Ewe, each with raw and composed
  APIs: two clients per run, 360 observed changes per combination, and 100%
  presence delivery. These bounded correctness checks used native k6 2.2.0;
  they do not establish capacity or validate the pinned k6 2.1.0 container.

## README.md

- Lines 67-70: The quick-start snippet passes
  `wire.dynamic_to_json(message.payload)` to `channel.broadcast` without handling
  its result. `packages/beryl/src/beryl/wire.gleam:199-200` returns
  `Result(json.Json, Nil)`, while
  `packages/beryl/src/beryl/channel.gleam:337-339` requires `json.Json`.
  The snippet does not type-check.
- Lines 247-248: The example table advertises chatroom pushes and collaborative
  document segment wildcards. Chatroom system messages use `channel.broadcast`,
  not `channel.push`
  (`examples/chatrooms/src/chatroom/app.gleam:145-172`). The document handler
  registers `"document:*"` and splits the captured suffix rather than
  registering `"document:*:*"`
  (`examples/collab_docs/src/collab_document/app.gleam:36-42,66-78`).
- Lines 355-359: The frame-buffering warning groups
  `with_max_connections_per_ip` with controls that run after frame assembly.
  The upgrade pipeline acquires a connection slot before accepting the upgrade
  (`packages/beryl/src/beryl/transport/server.gleam:369-388`), and that slot
  enforces per-IP and node limits
  (`packages/beryl/src/beryl/transport.gleam:36-49`). The separate warning about
  memory use within one admitted connection still applies.

## benchmarks/README.md

No drift detected.

## benchmarks/codec/README.md

No drift detected.

## benchmarks/codec/dev/README.md

No drift detected.

## benchmarks/codec/dev/beryl_codec_bench/README.md

No drift detected.

## docs/README.md

No drift detected.

## examples/README.md

No drift detected.

## examples/chatrooms/README.md

- Line 75: The API table says `GET /` requires `?token=beryl-demo`.
  The HTTP router serves the page without checking a token
  (`examples/chatrooms/src/chatroom/router.gleam:25-39`). The WebSocket
  connect hook validates the token
  (`examples/chatrooms/src/chatroom.gleam:69-76`).
- Lines 88-89: The event table lists `msg_ack` and `msg_error`, but
  `new_message` uses `channel.reply_ok` for successful messages and
  empty-message validation
  (`examples/chatrooms/src/chatroom/app.gleam:177-199`). The wire encoder
  emits `phx_reply`, not those named events
  (`packages/beryl/src/beryl/wire.gleam:295-320`).
- Lines 27-28,43: Feature descriptions attribute system messages to `Push`,
  group broadcasts to `group.broadcast()`, and room-name extraction to
  `beryl/topic`. The implementation uses `channel.broadcast` for system
  messages, `group.topics` for room membership, and
  `join_context.parameters` for the room name
  (`examples/chatrooms/src/chatroom/app.gleam:58-63,145-172,234-243`).

## examples/chatrooms/priv/README.md

No drift detected.

## examples/chatrooms/priv/static/README.md

No drift detected.

## examples/chatrooms/src/README.md

No drift detected.

## examples/chatrooms/src/chatroom/README.md

No drift detected.

## examples/collab_docs/README.md

- Line 12: The routing description claims a `"document:*:*"` segment-wildcard
  handler. The app registers `"document:*"` and requires two colon-separated
  components in the captured suffix
  (`examples/collab_docs/src/collab_document/app.gleam:36-42,66-78`).
  Tenant/document validation exists, but the routing description assigns it
  to the wrong mechanism.

## examples/collab_docs/client/README.md

No drift detected.

## examples/collab_docs/client/src/README.md

No drift detected.

## examples/collab_docs/priv/README.md

No drift detected.

## examples/collab_docs/priv/static/README.md

No drift detected.

## examples/collab_docs/scripts/README.md

No drift detected.

## examples/collab_docs/src/README.md

No drift detected.

## examples/collab_docs/src/collab_document/README.md

No drift detected.

## examples/cursors/README.md

No drift detected.

## examples/cursors/priv/README.md

No drift detected.

## examples/cursors/priv/static/README.md

No drift detected.

## examples/cursors/src/README.md

No drift detected.

## examples/cursors/src/cursor/README.md

No drift detected.

## examples/example_helpers/README.md

No drift detected.

## examples/example_helpers/src/README.md

No drift detected.

## examples/example_helpers/src/example_helper/README.md

No drift detected.

## examples/live_poll/README.md

No drift detected.

## examples/live_poll/src/README.md

No drift detected.

## examples/live_poll/src/live_poll/README.md

No drift detected.

## examples/load_test/README.md

- Lines 11-12: Source-run prerequisites call Erlang 27.2.1 and Gleam 1.16.0
  the repository versions. `.mise.toml:2-4` selects Erlang 28, Gleam 1.18.1,
  and just 1.50.0. The Docker pins are a separate configuration.
- Lines 46-47: The description calls the session tracker nonblocking.
  Channel handlers call `session_presence.track` and `untrack`
  (`examples/load_test/src/load_test/channel.gleam:118-120,141-143`).
  Those mutations use `process.call` with a 1,000 ms timeout
  (`examples/example_helpers/src/example_helper/session_presence.gleam:17,148-172,203-206`).
  Publication is asynchronous, but the caller waits for mutation completion.
- Lines 114-118: The successful `/stats` JSON example includes
  `beryl.runtime_mailbox_length`. The response constructor emits only
  `connected_sockets`, `joined_socket_topic_pairs`, and `active_topics` under
  `beryl` (`examples/load_test/src/load_test/http.gleam:26-42`).
- Lines 132-139: The `/stats` response table omits admission rejection.
  `stats_error` returns status 503 with
  `{"error":"runtime_admission_rejected"}` for `snapshot.AdmissionRejected(_)`
  (`examples/load_test/src/load_test/http.gleam:68-74`).

## examples/load_test/src/README.md

No drift detected.

## examples/load_test/src/load_test/README.md

No drift detected.

## examples/lustre_presence/README.md

No drift detected.

## examples/lustre_presence/client/README.md

No drift detected.

## examples/lustre_presence/client/src/README.md

No drift detected.

## examples/lustre_presence/client/src/lustre_presence_client/README.md

No drift detected.

## examples/lustre_presence/scripts/README.md

No drift detected.

## examples/lustre_presence/src/README.md

No drift detected.

## examples/lustre_presence/src/lustre_presence/README.md

No drift detected.

## examples/portable_channels/README.md

No drift detected.

## examples/portable_channels/src/README.md

No drift detected.

## examples/portable_channels/src/portable_channels/README.md

No drift detected.

## examples/showcase/README.md

No drift detected.

## examples/showcase/src/README.md

No drift detected.

## examples/showcase/src/showcase/README.md

No drift detected.

## examples/showcase/src/showcase/channel/README.md

No drift detected.

## load/README.md

- Lines 224-227: The target contract promises matching `presence_diff` entries
  for `presence_track` and `presence_untrack`. The target delegates to the
  session helper
  (`examples/load_test/src/load_test/channel.gleam:118-120,141-143`), which
  broadcasts flat `presence_list` snapshots
  (`examples/example_helpers/src/example_helper/session_presence.gleam:333-342`).
  The supplied profile expects `presence_diff`
  (`load/k6/profiles/presence-churn.json:24-26`), and the workload requires
  matching `joins` and `leaves` entries
  (`load/k6/scenarios/workloads.js:275-284`,
  `load/k6/lib/workload.js:22-28`). The documented target/workload pairing
  cannot satisfy that delivery contract.
- Lines 421-423: The CI smoke description says it installs Gleam 1.16.0.
  The workflow uses mise instead of that pin
  (`.github/workflows/ci.yml:424-443`), and `.mise.toml:3` selects Gleam 1.18.1.

## load/k6/README.md

No drift detected.

## load/k6/lib/README.md

No drift detected.

## load/k6/scenarios/README.md

No drift detected.

## packages/README.md

No drift detected.

## packages/beryl/README.md

No drift detected.

## packages/beryl/src/README.md

No drift detected.

## packages/beryl/src/beryl/README.md

No drift detected.

## packages/beryl/src/beryl/presence/README.md

No drift detected.

## packages/beryl/src/beryl/transport/README.md

- Lines 15-18,39-42: The interface lists `with_outbound_limits` without its
  failure boundary. It returns `Result(TransportConfig, OutboundConfigError)`
  and rejects nonpositive or oversized values
  (`packages/beryl/src/beryl/transport/server.gleam:201-224`).
  The public error variants appear at lines 86-95; the maxima are
  8,388,607 frames and 1,099,511,627,775 bytes at lines 44-46.

## packages/beryl/src/beryl/wire/README.md

No drift detected.

## packages/beryl_ewe/README.md

No drift detected.

## packages/beryl_ewe/src/README.md

No drift detected.

## packages/beryl_mist/README.md

No drift detected.

## packages/beryl_mist/src/README.md

No drift detected.

## packages/beryl_protocol/README.md

No drift detected.

## packages/beryl_protocol/src/README.md

No drift detected.

## scripts/README.md

No drift detected.

## website/README.md

No drift detected.

## website/scripts/README.md

No drift detected.

## website/src/README.md

No drift detected.

## website/src/components/README.md

No drift detected.

## Verification limitations

- This review compared documentation with local source. It did not run builds,
  installations, load tests, servers, or browser suites.
- The review excluded ordinary tests, generated bundles, dependencies, and
  build trees. It inspected shared verification infrastructure and mocks.
- The review did not audit imported CRDT algorithms or transport dependency
  internals. Dependency-level buffering claims in the root README remain
  unverified beyond the local adapter boundary.
- The review did not verify remote release/deployment availability or the
  advertised count of ordinary tests.
