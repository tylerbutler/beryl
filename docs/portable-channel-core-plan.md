# Portable channel core implementation plan

Status: Proposed implementation sequence

Source: [Portable channel protocol core](portable-channel-core-spec.md)

## Outcome and boundaries

Add a dual-target `beryl_protocol` package, route beryl's protocol lifecycle
through it, and validate a Cloudflare Durable Object example with the official
Phoenix JavaScript client. Keep the existing BEAM APIs, codecs, transports,
supervision, PubSub, presence, and channel workers.

Use the phases below as small pull requests. Adopt each extracted lifecycle
path in the BEAM runtime before extracting the next one. Do not retain an
alternative production implementation or add a runtime migration flag.

This plan does not include Monk changes or deployment.

## Current implementation map

Paths in this table are relative to the repository root.

| Concern | Current code and regression tests |
| --- | --- |
| Decoded dispatch and validation | `packages/beryl/src/beryl/runtime.gleam`: `dispatch_inbound`, `resolve_event_topic`, `is_valid_topic`, `is_valid_event`; public validation in `beryl/topic.gleam` |
| Join and replacement | Runtime: `handle_join_inner`, `execute_deliver_join`, `apply_accept_join`, `apply_reject_join`, `matching_pending_join`; `app_dispatch_test.gleam`, `app_protocol_test.gleam` |
| Membership and cleanup | Runtime: `execute_close_topic`, `unsubscribe_topic`, `execute_close_cleanup`, `execute_teardown`; `app_presence_async_test.gleam`, `app_kick_stop_test.gleam`, `channel_lifecycle_actions_test.gleam` |
| Reply capabilities and capacity | `beryl/socket.gleam`: opaque `JoinReference` and `ReplyReference`; runtime: `route_message_with_ref`, `register_reply_reference`, `apply_reply`, `apply_discard_reply`; `app_ref_test.gleam`, `runtime_overload_test.gleam` |
| Heartbeats | Runtime: `handle_heartbeat`, `handle_check_heartbeats`; `app_heartbeat_test.gleam`, `protocol_hardening_test.gleam` |
| Framing and codec options | `beryl/wire.gleam`, `beryl/wire/codec.gleam`; `wire_codec_test.gleam`, `phoenix_binary_test.gleam`, `per_socket_codec_test.gleam`, `app_topic_fallback_test.gleam` |
| Ordering and channel parity | `effect_ordering_test.gleam`, `channel_wire_matrix.gleam`, `channel_wire_matrix_test.gleam`; Mist's `phoenix_contract_test.gleam` and both transport suites |

Test filenames without a directory prefix are under `packages/beryl/test/`.
The runtime's `Step` interpreter already handles asynchronous cleanup. Keep
that interpreter in the BEAM host.

## Core and host contract

Start with one public module, `beryl_protocol`, rather than separate modules
for each type. Add a module only when its API needs an independent boundary.

The public contract should provide:

- An opaque configuration and per-connection state, with validated limits.
- Normalized decoded inputs and application decisions.
- Opaque connection/channel generations and join/reply operation handles.
- `step(state, input, now_ms) -> Result(#(State, List(Action)), Error)`.
- Ordered actions for application delivery, logical outbound messages,
  host cleanup, connection closure, and deadline updates.
- Versioned export and restore functions over data without host resources.

Keep payloads compatible with the existing decoded `Dynamic` and outbound
`gleam_json.Json` values. Keep those values out of the membership ledger unless
an active transition needs them. Do not import beryl from the new package.
The BEAM adapter converts its existing codec types to the core types, and
converts logical outbound actions back through the active codec.

### Identity and capacity

Use a trusted host-issued connection epoch plus core-issued channel and
operation counters. Client topics, join references, and message references
must not determine capability identity. Preserve counters across restoration;
reject invalid values and handle JavaScript safe-integer exhaustion without
wrapping. A new connection must receive a new epoch even if its socket ID
matches an old connection.

Keep the public BEAM handles opaque and unchanged for callers. Map their
existing Erlang-reference identity to core handles in the adapter. Remove
each mapping on completion, discard, rejection, or final topic cleanup.
Do not use a wire-field tuple as the capability lookup key.

The core must bound retained pending operations. The BEAM host must also keep
its existing count/byte admission reservations. Reserve host capacity before
committing delivery; feed admission failure back through the core's close
path. Release reservations and core capacity together. An operation-count
limit must not replace the existing byte budget.

### Ordering and host completion

Execute actions in order. Feed callback results back as inputs before
processing later external inputs for that connection. Translate host work
that can suspend or fail into a small completion input with an operation ID.
Use this for subscription admission and cleanup barriers as required.

The core must not declare a replacement ready before the old instance's
cleanup completes. The host retains its queue, timers, reservations, and
continuation stack; the core retains only the lifecycle state needed to
validate the completion. Reject late completions from an old generation.

Define `Error` as a rejected transition with no committed state or actions.
Represent normal wire rejection, stale-input drops, and timeout closure as
successful transitions with their required actions. Hosts must define their
response to codec, callback, persistence, and send failures; a failed action
must not allow later actions to bypass cleanup.

## Implementation sequence

### 1. Record compatibility rules and test cases

Before changing production routing, add focused cases to the existing test
files where coverage is missing. Record the expected normalized inputs,
actions, and wire results for reuse in the pure suite.

Cover these existing details:

- Reject invalid/reserved topics and reserved `phx_` application events.
  Preserve UTF-8 byte limits and topicless-event resolution.
- Close a same-topic instance through its normal path before delivering its
  replacement join. Reject an unanswered join at the end of the BEAM callback
  turn; do not extend the public join API to deferred authorization.
- Send a join acknowledgment before initial pushes. Drop a push before
  acceptance. Send a referenced leave acknowledgment before its terminal frame.
- Drop stale events/leaves when both supplied and current join references
  exist and differ. Preserve current behavior for omitted join references.
- Reject duplicate outstanding effective wire keys with `duplicate_ref`.
  Allow reuse after reply, discard, or closure without reviving an old handle.
- Preserve the heartbeat `elapsed > timeout` boundary and rate-limiter order.
  Ordinary application traffic must not refresh the heartbeat deadline.
- Preserve closing-worker behavior: apply already-computed worker results
  before invalidating their reply handles at final cleanup. Raw-dispatch
  topics invalidate their handles before delivering `Closed`.

**Gate:** Existing tests plus new characterization cases pass before extraction.
Use explicit mailbox selectors and polling helpers in asynchronous tests.

### 2. Add the portable package and adopt validation

Create `packages/beryl_protocol/` with its manifest, public module, and a
target-neutral test entry point. Use standard-library dependencies first;
add `gleam_json` if the chosen logical message types require it. Keep OTP,
Erlang references, Roost, clocks, and transport callbacks outside the package.
Use a test runner whose dependency graph supports both targets; do not copy
the BEAM-only setup from `beryl_test.gleam`.

Add beryl's path dependency with Gleam tooling and update affected manifests.
The existing `packages/*` workspace glob already discovers the package.

Implement state/configuration construction and shared topic/event validation,
then route the runtime's validation through it. Keep `beryl/topic` signatures,
error variants, and validation scope compatible; translate errors rather than
exposing new variants through existing exhaustive public types. Leave topic
matching and logging sanitization in beryl unless extraction requires them.

Add a scoped recipe that builds strictly and runs the same pure test entry
point on Erlang and JavaScript. Keep JS compilation an early gate.

**Gate:** Both targets pass validation cases, beryl uses the shared rules, and
existing codec/topic tests pass without public API changes.

### 3. Extract join, membership, and closure transitions

Implement pending joins, authorization decisions, accepted membership, leave,
kick, replacement, and connection-close transitions. Include callback-turn
completion so the BEAM adapter can preserve unanswered-join rejection.

Add the core state to each runtime `SocketState`. Route the join and close
paths through it and translate actions into existing runtime steps. Preserve
subscription-index admission, worker release, presence cleanup, terminal
frames, callback failures, and shutdown behavior.

Represent closing as a lifecycle phase where needed. Let the host signal
completion after draining committed worker reports and presence cleanup.
Do not implement BEAM workers or their queues in the core.

Replace the old protocol membership decisions as each path moves. Keep router
subscriber indexes as host-owned delivery indexes, updated from core actions;
do not treat them as an independent protocol state machine.

**Gate:** Pure action-order cases pass on both targets. Raw-dispatch/channel
parity, replacement, crash, kick, presence-cleanup, and transport tests pass.

### 4. Extract message correlation and reply lifecycle

Move outstanding wire-key detection, unique reply operations, reply/discard
consumption, and generation checks into the core. Route decoded application
messages and BEAM reply effects through those transitions.

Keep the BEAM reference-to-core mapping and queue reservations as host data.
Remove `pending_reply_keys` and other superseded protocol decisions from the
runtime once the core owns them. Preserve the closing-worker timing from
phase 1 rather than invalidating all handles at close initiation.

Test late join decisions, deferred replies, duplicate completion, cross-topic
and cross-connection handles, reused join/message references, discard, and
capacity release. At each capacity boundary, verify both the core ledger and
the host reservation return to their prior level after cleanup.

**Gate:** `app_ref_test.gleam`, overload/memory tests, worker lifecycle tests,
and shared pure correlation cases pass. Late work cannot consume a new handle.

### 5. Extract heartbeat and deadline decisions

Move heartbeat reply correlation, last-heartbeat state, expiry decisions, and
next-deadline calculation into the core. Supply time from the host.

Keep BEAM timer scheduling, rate limiting, telemetry, and timeout execution
in the runtime. Preserve its bounded deferral while a socket waits for a
presence acknowledgment. Do not tighten effective eviction timing merely
because the core can report an exact deadline.

Test exact-boundary expiry, duplicate/late timer events, dropped over-rate
heartbeats, independent connections, closure, and timeout during cleanup.
After a timer fires, the host must recompute the deadline from current state.

**Gate:** Both-target deadline cases and existing heartbeat, abuse-control,
async-presence, and parity tests pass.

### 6. Define restoration and recovery

Add a versioned, validated export format for protocol state. Include connection
identity, channel generations, wire correlation, next operation counters,
limits needed to validate the ledger, and portable deadline metadata. Bound
attachment size and collection sizes; reject unknown versions and inconsistent
references. Do not serialize callbacks, process handles, queue reservations,
raw credentials, or application models.

Keep durable wall-clock timing metadata in the host attachment envelope.
On restore, account for time spent asleep and rebase remaining time onto the
new runtime's clock. Do not compare monotonic timestamps across instances.
Define a conservative close/rejoin policy for invalid or backward clock data.

Use this initial recovery policy:

- Retain established membership and generations when the host can reconstruct
  its authority and no application work needs recovery.
- Invalidate unrecoverable pending joins, replies, and host operations. Preserve
  identity counters so their late completions cannot match new work.
- Require affected channels to rejoin through authorization, using Phoenix
  error/close behavior verified with the client. A failed or incompatible
  restore closes the connection and lets the client reconnect.
- Reconstruct the next deadline and process overdue cleanup before accepting
  new commands. Rehydrate host application state before resuming delivery.

**Gate:** Cross-target snapshot round trips preserve recoverable state.
Malformed exports, lost work, repeated restore, reference reuse, and elapsed
hibernation cannot revive operations or skip required cleanup.

### 7. Build the Durable Object example and client tests

Add a release-excluded example under `examples/portable_channels/`. Use one
Durable Object per match, with independent protocol state per WebSocket.
Add the example to the explicit examples pnpm workspace.

First verify Roost's current JavaScript API, dependency graph, and Phoenix
text/binary fixture behavior. Use it only in the example's framing adapter;
keep beryl's existing codec implementation and public types unchanged.

Use Cloudflare's local runtime/test tools to exercise WebSocket acceptance,
hibernation attachments, wake-up, alarms, and close events. A plain JavaScript
WebSocket mock is not sufficient evidence for hibernation.

The host must:

- Serialize transitions and action execution per connection, including across
  asynchronous authorization and persistence.
- Authenticate from the join payload and validate `match:<code>` against the
  owning object. Reauthorize and send a fresh snapshot after rejoin.
- Save attachments at defined transition boundaries. Define crash behavior
  between checkpointing, application execution, and sending replies; attachment
  persistence alone does not provide exactly-once command execution.
- Schedule the earliest connection deadline with the object's alarm, process
  due connections on wake-up, and re-arm after membership/deadline changes.
- Keep disconnect/channel leave separate from leaving the application roster.

Use a small authoritative test model with stable command IDs and a durable
deduplication record. Test with the official `phoenix` npm client: authorization
failure, join/push order, replies, leave/rejoin, heartbeat loss, hibernation,
lost pending work, and retry after a lost reply. Assert that retries do not
repeat application mutations. Do not claim that Phoenix references provide
application deduplication.

Reuse shared Phoenix wire fixtures for framing checks. Keep raw framing tests
for cases that the official client cannot generate.

**Gate:** The official client completes the lifecycle and recovery tests against
the local Durable Object runtime. No Monk code or deployment is required.

### 8. Complete CI, documentation, and release integration

Add the dual-target pure suite and Durable Object integration suite to CI.
Keep required jobs running with successful no-op steps when paths do not
require expensive checks.

Check the full production dependency graph of `beryl_protocol` and the JS
example for BEAM-only packages and unsupported externals. Combine dependency
inspection with a strict JavaScript build; either check alone is incomplete.
Keep development-only lint/test dependencies separate from the shipped graph.

Review hard-coded three-package assumptions, including audit recipe defaults,
snippet dependencies, and contributor docs. The reference generator already
discovers packages under `packages/`; document the new public API in source
comments and regenerate reference pages with `just docs`.

Document action execution, admission failures, cleanup completion, capability
identity, clock rules, attachment versioning, rejoin recovery, and application
deduplication. Include a short example-host setup guide.

Add release fragments for the new package and consumer-visible beryl changes.
Do not add fragments for example, CI, or plan-only changes.

**Gate:** Complete the acceptance matrix below. Confirm that beryl has no
remaining independent implementation of the extracted protocol decisions.

## Validation and release gates

| Scope | Required evidence |
| --- | --- |
| Pure protocol | Identical transition cases on Erlang and JavaScript: validation, join rejection/replacement, action order, stale generations, deferred replies, reference reuse, capacity, heartbeat expiry, export/restore |
| BEAM adoption | Focused tests after each path, then `just test beryl`, `just test beryl_mist beryl_ewe`; retain the raw-dispatch/channel parity matrix and distributed cleanup coverage |
| Framing compatibility | Existing text/binary/custom-codec tests plus shared Phoenix fixtures through the Roost adapter |
| JavaScript host | Official Phoenix client against the local Durable Object runtime, including wake-up, overdue deadlines, pending-work loss, and stable-command retry |
| Public compatibility | Existing public function/type signatures, transport SPI, and channel import boundary remain intact; downstream examples compile |
| Final branch | `just format-check`, `just lint`, `just build-strict`, `just beam-check`, `just doctor`, new dual-target/host recipes, and `just pr` against the current default branch |
| Review | BEAM-specific review of changed Gleam/Erlang source, tests, and examples; API review of the new portable contract before its first release |

Do not run a separate type check before a build/test for the same scope.
Update manifests through Gleam tooling after dependency changes. Preserve the
existing serial-test lane for VM-wide or scheduling-sensitive tests.

## Decisions to settle before the relevant phase

These are implementation decisions, not reasons to delay characterization:

| Decision | Proposed starting point | Resolve by |
| --- | --- | --- |
| Portable payload and action types | Existing `Dynamic` inbound and `Json` outbound; no retained application payloads in stable membership state | Phase 2 API tests |
| Host completion protocol | Generation-scoped completion IDs for fallible admission and cleanup; retain host continuation machinery | Phase 3 |
| Pending capacity defaults | Match existing BEAM behavior and document the independent portable bound; no new timeout for BEAM deferred replies | Phase 4 |
| Clock and lost-work recovery | Rebase from host wall-clock metadata; require rejoin for unrecoverable work | Phase 6 |
| Roost and Cloudflare tooling | Verify supported versions and fixture compatibility before selecting dependencies | Phase 7 |

The main risk is a lifecycle-order regression during BEAM adoption, especially
around in-flight worker results and asynchronous presence cleanup. The early
characterization cases and per-path integration gates address that risk.
Cloudflare hibernation and Roost compatibility remain unverified until the
example runs; do not integrate Monk before that gate passes.
