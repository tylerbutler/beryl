# Gleam FFI reduction plan

## Status

In progress. The PubSub actor migration in phase 7 is complete. Phases 1
through 6 remain.

## Objective

Reduce the Erlang source maintained by beryl by moving suitable runtime
primitives to typed Gleam modules.

Use `rasa` for atomic integers and monotonic clocks. Use existing
`gleam_erlang` process APIs where they preserve the current behavior. Keep
small Erlang adapters when they express a BEAM operation more clearly than a
Gleam workaround or when available libraries do not preserve beryl's
contracts.

This plan excludes the PubSub actor migration, which is covered by
`docs/pubsub-typed-actor-plan.md`. The `lattice_presence` API work is tracked
upstream in `tylerbutler/lattice#199`.

## Decision summary

| Current area | Decision |
|---|---|
| Admission and reservation tokens | Replace with a typed Gleam module using `rasa/atomic` |
| Outbound frame and byte budget | Replace with a typed Gleam module using `rasa/atomic` |
| Monotonic clocks | Replace with `rasa/monotonic` after `rasa` is added |
| Supervisor shutdown | Replace with `gleam_erlang/process` |
| Conditional process send | Replace with `gleam_erlang/process` |
| Unused identity and string-prefix exports | Delete |
| `lattice_presence` tuple operations | Replace with upstream public APIs from `tylerbutler/lattice#199` |
| Exception rescue and bounded formatting | Keep Erlang |
| Abnormal-exit formatting | Keep Erlang |
| Connection-limit reply aliases | Keep Erlang |
| Checkpoint ancestor and `persistent_term` access | Keep Erlang |
| Presence read-model ETS table | Keep Erlang |
| Generic telemetry execution and mailbox length | Keep Erlang |
| Bounded ETS work queue | Keep Erlang |

## Scope

### In scope

- Add `rasa` as a beryl runtime dependency.
- Replace beryl-owned atomic wrappers with `rasa/atomic`.
- Replace monotonic clock FFI with `rasa/monotonic`.
- Move supervisor shutdown to existing `gleam_erlang` APIs.
- Move the connection limiter's conditional send to `gleam_erlang`.
- Delete unused Erlang exports.
- Remove `beryl_presence_state_ffi.erl` after the required public
  `lattice_presence` release is available.
- Reduce `beryl_ffi.erl` to the operations that still need a direct BEAM
  boundary.
- Preserve public APIs, runtime behavior, failure behavior, and wire formats.
- Add focused tests for every moved state machine.

### Not in scope

- Rewrite the bounded work queue around `rasa/queue`.
- Rewrite the presence read model around `rasa/table`.
- Replace Erlang `telemetry` with OpenTelemetry.
- Change callback failure handling or log metadata.
- Change connection-limit timeout or late-reply behavior.
- Replace the checkpoint's supervisor-generation registry.
- Wrap all of Erlang/OTP in local Gleam modules.
- Expose the new internal atomic modules as public APIs.
- Change beryl's Erlang/OTP version floor.

## Dependency

Add:

```toml
rasa = ">= 2.1.0 and < 3.0.0"
```

`rasa` 2.1.0 is an Erlang-target Gleam package. It depends on
`gleam_stdlib` and `gleam_erlang`, which beryl already uses. Its MIT licence is
already permitted by beryl's licence policy.

Update `gleam.toml` and `manifest.toml` through Gleam tooling. Do not hand-edit
only the manifest.

Adding `rasa` moves low-level Erlang maintenance to a focused dependency; it
does not remove BEAM atomics from the deployed application. The benefit is
that beryl's state machines become type-checked Gleam code and local
maintainers no longer need to modify Erlang CAS loops.

## Shared atomic token

### Target module

Add:

```text
packages/beryl/src/beryl/atomic_token.gleam
```

Declare it in `internal_modules`.

The module should import only:

- `gleam/erlang/process`
- `rasa/atomic`

It must not import runtime, transport, or connection-limit modules.

### State model

Use one signed 64-bit `rasa.Atomic`:

```text
0 = pending
1 = claimed
2 = cancelled
```

Keep the creator PID beside the atomic:

```gleam
pub opaque type Token {
  Token(state: atomic.Atomic, owner: process.Pid)
}
```

Suggested internal API:

```gleam
pub fn new() -> Token
pub fn owner(token: Token) -> process.Pid
pub fn cancel(token: Token) -> Bool
pub fn claim_if_owner_alive(token: Token) -> Bool
pub fn pending_if_owner_alive(token: Token) -> Bool
pub fn pending(token: Token) -> Bool
```

`cancel` performs `compare_exchange(0, 2)`. `claim_if_owner_alive` checks the
creator PID and then performs `compare_exchange(0, 1)`.
`pending_if_owner_alive` combines owner liveness with an atomic read.
`pending` reads only the atomic state.

The distinction between the two pending functions is required:

- socket admission is valid only while the process that created the token is
  alive;
- connection reservations can transfer ownership after creation, so their
  pending check must not depend on the creator.

Do not make the state integers public. Do not provide a generic integer setter.

### Integration

Replace the opaque FFI token declarations in:

- `packages/beryl/src/beryl/runtime.gleam`
- `packages/beryl/src/beryl/connection_limit.gleam`

Use aliases for the shared internal type if local names make the call sites
clear:

```gleam
type AdmissionToken =
  atomic_token.Token

type ReservationToken =
  atomic_token.Token
```

Delete these `beryl_ffi.erl` functions after parity tests pass:

- `admission_token_new/0`
- `admission_token_cancel/1`
- `admission_token_owner/1`
- `admission_token_pending/1`
- `admission_token_claim/1`
- `reservation_token_pending/1`

## Outbound budget

### Target module

Add:

```text
packages/beryl/src/beryl/outbound_budget.gleam
```

Declare it in `internal_modules`.

The module should import:

- `gleam/erlang/process`
- `gleam/int`
- `rasa/atomic`

### State model

Preserve the current packed signed 64-bit state:

```text
bits 0..39  = reserved payload bytes
bits 40..62 = reserved frame count
negative    = permanently closed
```

Keep the packed representation private:

```gleam
pub opaque type Budget {
  Budget(state: atomic.Atomic)
}
```

Suggested API:

```gleam
pub fn new() -> Budget

pub fn reserve_and_send(
  budget: Budget,
  subject: process.Subject(message),
  message: message,
  bytes: Int,
  max_frames: Int,
  max_bytes: Int,
) -> Bool

pub fn release(budget: Budget, bytes: Int) -> Nil

pub fn close_and_send(
  budget: Budget,
  subject: process.Subject(message),
  message: message,
) -> Nil

pub fn cancel(budget: Budget) -> Nil
```

The current transport always sends `Close` from `close_and_send`, but passing
the message keeps the atomic module independent of transport types.

### CAS rules

`reserve_and_send` must:

1. Read the current packed value.
2. Reject a negative value.
3. Decode the frame and byte counts.
4. If either configured limit would be exceeded, atomically close the budget
   and return `False`.
5. Otherwise compare-and-exchange the incremented packed value.
6. Retry with the actual value returned by a failed compare-and-exchange.
7. Send only after the reservation succeeds.

`release` must subtract one frame and the supplied byte count without going
below zero. It must do nothing after closure.

`close_and_send` must send exactly once: only the caller that changes a
non-negative value to the closed sentinel sends the close message.

`cancel` may set the closed sentinel without sending.

Use `process.send` after a successful state transition. Unlike PubSub, outbound
transport messages already use a normal Gleam `Subject`, so the subject tuple
is the correct wire shape.

### Numeric limits

The packed state has hard ceilings:

- frame count must fit in 23 bits;
- byte count must fit in 40 bits;
- the complete packed value must remain non-negative.

Confirm that configuration validation rejects values outside these ranges.
If it does not, add validation before replacing the Erlang code. Do not rely on
`rasa` overflow behavior; its arithmetic wraps silently.

### Integration

Replace the FFI declarations in:

```text
packages/beryl/src/beryl/transport/server.gleam
```

Delete `beryl_outbound_ffi.erl` after focused concurrency and close-once tests
pass.

## Monotonic clocks

Once `rasa` is already required for atomics, use:

```gleam
monotonic.time(monotonic.Millisecond)
monotonic.time(monotonic.Nanosecond)
monotonic.time(monotonic.Native)
```

Replace clock declarations in:

- `beryl/runtime.gleam`
- `beryl/presence.gleam`
- `beryl/rate_limit.gleam`
- `beryl/connection_limit.gleam`
- `beryl/telemetry.gleam`

Use the exact existing unit at each call site:

| Area | Unit |
|---|---|
| Socket heartbeat and presence deadlines | Millisecond |
| Rate limits and connection bucket expiry | Nanosecond |
| Erlang telemetry duration measurements | Native |

Do not use `monotonic.unique`; these call sites measure elapsed time and do
not require globally unique integers.

After conversion, delete:

- `beryl_ffi:monotonic_time_ms/0`
- `beryl_ffi:monotonic_time_ns/0`
- `beryl_telemetry_ffi:monotonic_time/0`

Keep tests expressed as elapsed durations. Do not assert absolute monotonic
values.

## Supervisor shutdown

Move `stop_supervisor` into
`packages/beryl/src/beryl/app_supervisor.gleam`.

Preserve this sequence:

1. Unlink from the supervisor with `process.unlink`.
2. Monitor the supervisor with `process.monitor`.
3. Send an abnormal exit whose reason is the atom `shutdown`.
4. Wait up to five seconds for that specific monitor.
5. If the monitor reports the process down, return.
6. On timeout, demonitor it and call `process.kill`.

Use `process.select_specific_monitor`. Do not use a selector that accepts any
monitor message; stale mailbox state must not complete the shutdown.

The shutdown atom is a fixed internal value. It must not come from user input.

Delete `beryl_ffi:stop_supervisor/1` after the app-supervision tests pass.

## Conditional process send

Replace `beryl_ffi:connection_limit_send/2` in Gleam:

1. Call `process.subject_owner`.
2. Return `False` if a named subject is not registered.
3. Check `process.is_alive`.
4. Send through `process.send` and return `True` only for a live owner.

The liveness check and send are not atomic; the current Erlang implementation
has the same race. Delivery remains best-effort.

Keep `connection_limit_call/3` in Erlang. `process.call` does not preserve its
typed timeout and owner-down errors, and it does not expose the reply-alias
cleanup that drops late replies.

## Delete unused exports

No Gleam call sites use these `beryl_ffi.erl` exports:

- `identity/1`
- `string_starts_with/2`

Delete them instead of replacing them.

If a new prefix check is needed later, use `gleam/string.starts_with`.

## `lattice_presence` conversion

After a `lattice_presence` release resolves `tylerbutler/lattice#199`:

1. Update the dependency with Gleam tooling.
2. Replace `owner_snapshot` with the new public owner-only snapshot function.
3. Replace `remove_tag` with the new public exact-tag removal function.
4. Delete `beryl_presence_state_ffi.erl`.
5. Remove comments that describe the private runtime tuple.
6. Run presence convergence, replication, retirement, and wire round-trip
   tests.

Do not copy the current tuple manipulation into Gleam. The type is opaque, and
the representation belongs to `lattice_presence`.

## Erlang boundaries to keep

### Callback rescue

Keep `beryl_ffi:rescue/1`.

The current adapter catches errors, exits, and throws, formats with limited
depth, limits generated characters, truncates to 512 characters, and copies
the final binary. The `exception` package catches the exception classes but
does not provide the same bounded formatting contract.

This is small security and reliability code. Replacing it with a larger Gleam
pipeline would be harder to verify.

### Abnormal-exit descriptions

Keep `beryl_error_ffi:describe_abnormal_exit/1`.

No maintained Gleam wrapper exposes OTP's exception formatter with beryl's
depth and output limits. The current adapter is short and isolated.

### Connection-limit calls

Keep `beryl_ffi:connection_limit_call/3`.

It uses a reply alias, a process monitor, a timeout, and explicit cleanup to
ensure that late replies do not remain in the caller's mailbox. This behavior
is not available through the current public `gleam_erlang` API.

### Checkpoint generation registry

Keep these operations together in a small checkpoint-specific Erlang module:

- read the supervisor ancestor;
- build the `persistent_term` key;
- get and put the inherited table;
- erase only when the current value matches the expected table.

Move them out of the generic `beryl_ffi.erl` after the atomic conversions.
Suggested module:

```text
packages/beryl/src/beryl_checkpoint_ffi.erl
```

The Erlang code is small and directly represents OTP process metadata and
`persistent_term` compare-before-erase behavior. A general wrapper would make
the ownership rule less clear.

### Presence read model

Keep `beryl_presence_read_ffi.erl`.

`rasa/table` does not provide all required behavior:

- a stable named table that follows the presence actor name;
- protected writes with public concurrent reads;
- `read_concurrency`;
- atomic replacement of the topic snapshot;
- count-only `lookup_element`;
- distinct missing-topic and missing-table outcomes.

Do not replace these operations with actor calls. Direct reads are an
intentional performance and availability property.

### Telemetry

Keep event mapping and mailbox inspection in `beryl_telemetry_ffi.erl`, but
remove its monotonic clock function.

The event adapter converts typed Gleam constructors into atom-keyed Erlang
telemetry events and metadata. Keeping this mapping in one mechanical Erlang
module is clearer than exposing `Dynamic` maps and atom coercions throughout
Gleam code.

`gleam_erlang` does not expose `process_info/2` for mailbox length. Keep the
small binding in the same module.

### Bounded work queue

Keep `beryl_work_queue_ffi.erl`.

`rasa/queue` supplies an unbounded FIFO queue, but beryl requires one atomic
state transition across:

- item and structural byte limits;
- pending order;
- leases;
- retained output;
- producer cleanup;
- close state and close reason;
- cancellation counters;
- high-water telemetry;
- named incarnation lookup.

Combining `rasa/queue` and `rasa/atomic` would split that transaction across
multiple stores. It would require rollback and new crash-recovery rules while
still retaining most of beryl's custom code.

Revisit this decision only if a maintained Gleam package provides an atomic
bounded enqueue with reservations, cleanup ownership, and byte accounting.

## Resulting Erlang layout

The intended package-owned Erlang source after this plan and the PubSub plan
is:

```text
packages/beryl/src/
├── beryl_checkpoint_ffi.erl
├── beryl_error_ffi.erl
├── beryl_presence_read_ffi.erl
├── beryl_telemetry_ffi.erl
├── beryl_work_queue_ffi.erl
├── beryl_pubsub_supervisor.erl   # only if the Gleam version is less clear
└── beryl_pubsub_ffi.erl          # only small remaining OTP startup adapters
```

`beryl_ffi.erl`, `beryl_outbound_ffi.erl`, and
`beryl_presence_state_ffi.erl` should be deleted when their migrations are
complete. If callback rescue remains the only operation preventing deletion
of `beryl_ffi.erl`, rename it to `beryl_rescue_ffi.erl`.

Each retained module must have one narrow purpose. Avoid recreating a generic
utility FFI file.

## Migration phases

### Phase 1: add `rasa` and convert clocks

1. Add `rasa` with Gleam tooling.
2. Replace all monotonic clock declarations.
3. Remove the three clock functions from beryl FFI modules.
4. Run timing, heartbeat, rate-limit, presence, and telemetry tests.

This phase validates the dependency and time-unit mapping before moving CAS
state.

### Phase 2: convert atomic tokens

1. Add `beryl/atomic_token.gleam`.
2. Add focused state-transition tests.
3. Migrate runtime admission tokens.
4. Migrate connection reservation tokens.
5. Delete the six token functions from `beryl_ffi.erl`.

### Phase 3: convert the outbound budget

1. Confirm or add packed-range configuration validation.
2. Add `beryl/outbound_budget.gleam`.
3. Add focused concurrent reservation, release, close-once, and cancellation
   tests.
4. Migrate `beryl/transport/server.gleam`.
5. Delete `beryl_outbound_ffi.erl`.

### Phase 4: convert process helpers

1. Move supervisor shutdown to `app_supervisor.gleam`.
2. Move conditional connection-limit send to Gleam.
3. Delete unused identity and prefix exports.
4. Run app-supervision and connection-limit tests.

### Phase 5: split retained FFI by purpose

1. Move checkpoint functions to `beryl_checkpoint_ffi.erl`.
2. Rename the generic module to `beryl_rescue_ffi.erl` if rescue is its only
   remaining function.
3. Run Dialyzer and Xref checks after module renames.

### Phase 6: remove private lattice state access

1. Wait for a `lattice_presence` release containing the APIs from
   `tylerbutler/lattice#199`.
2. Update the dependency.
3. Migrate both operations.
4. Delete `beryl_presence_state_ffi.erl`.

### Phase 7: complete the PubSub actor plan

Completed in `245736a6`.

- Membership intent and recovery now live in
  `beryl/pubsub_memberships.gleam`.
- `beryl_pubsub_memberships.erl` was deleted.
- `beryl_pubsub_supervisor.erl` remains because `gleam_otp` does not provide
  the keyed, concurrent dynamic-child contract required for lazy scopes.
- Test-only Erlang remains only where tests need `sys`, process dictionaries,
  direct OTP child failure, or inspection of the flat distributed wire tuple.

No further PubSub work is required by this plan.

## Test plan

### Atomic token tests

- New tokens are pending.
- One caller can claim a token.
- A claimed token cannot be cancelled.
- A cancelled token cannot be claimed.
- Repeated cancellation returns `False`.
- Admission pending becomes false when its creator exits.
- Reservation pending does not depend on creator liveness.
- Concurrent claim and cancel produce exactly one successful transition.

### Outbound budget tests

- Reservations enforce both item and byte limits.
- A successful reservation sends exactly one message.
- A failed reservation sends no data message and closes admission.
- Concurrent reservations cannot exceed either limit.
- Release makes capacity available while the budget is open.
- Release after closure changes nothing.
- Only one caller sends `Close`.
- Cancellation closes without sending.
- Boundary values do not overflow the packed integer.

### Process helper tests

- Supervisor shutdown waits for normal cleanup.
- Shutdown kills a supervisor that does not stop within the timeout.
- The selector ignores unrelated monitor messages.
- Conditional send returns false for a dead PID and an unregistered name.
- Conditional send preserves the existing best-effort race semantics.

### Integration tests

Retain and run:

- app supervision and restart-intensity tests;
- connection admission, cancellation, and checkpoint tests;
- runtime overload tests;
- transport queue and close tests;
- heartbeat and presence timeout tests;
- telemetry duration and queue occupancy tests;
- all presence replication and convergence tests after the lattice update.

Use exact mailbox selectors and drain messages created by each test.

## Validation

For each phase, run the smallest focused tests first. Before merging the full
migration, run:

```bash
just format
just format-check
just check
just test
just lint
just beam-check
just build-strict
just doctor
```

Run `just docs` if public or module documentation changes.

Use `just change beryl Dependencies "<body>"` when `rasa` is added. Add a
separate beryl fragment for any consumer-visible behavior change. Do not add a
fragment for the plan documents or behavior-preserving internal refactors.

## Risks and controls

### Atomic overflow

`rasa` matches Erlang atomics and wraps signed 64-bit arithmetic on overflow.
Keep explicit range validation and boundary tests for packed budgets. Never use
unchecked `add` or `sub` where overflow changes admission behavior.

### Changed race behavior

Moving a CAS loop to Gleam can change when the message send occurs relative to
the successful exchange. Keep the send after the successful reservation and
test concurrent close and release paths.

### Public type leakage

Do not expose `rasa.Atomic`, token states, or packed budget integers through
beryl's public API. All new modules are internal.

### Dependency without enough benefit

Do not adopt `rasa/table` or `rasa/queue` only because `rasa` is already
installed. Each use must replace a complete beryl-owned invariant, not one
primitive inside a larger custom transaction.

### FFI fragmentation

Splitting the generic module must produce a few purpose-specific adapters, not
one Erlang file per function. Group functions by the BEAM concept and
invariant they implement.

### Upstream API delay

The lattice conversion is independent of the `rasa` work. Do not block atomic,
clock, or supervisor changes while waiting for `tylerbutler/lattice#199`.

## Completion criteria

The migration is complete when:

- `rasa` owns atomic and monotonic BEAM primitives used by beryl;
- admission tokens and outbound budgets are implemented in typed Gleam;
- supervisor shutdown and conditional sends use `gleam_erlang`;
- unused generic FFI exports are deleted;
- `beryl_ffi.erl` is deleted or reduced and renamed to a narrow rescue module;
- private `lattice_presence` tuple matching is removed after the upstream
  release;
- retained Erlang modules are small, purpose-specific, and easier to review
  than available Gleam or library alternatives;
- all focused tests and repository validation commands pass;
- public APIs, wire formats, overload behavior, and restart behavior remain
  unchanged unless a separate change explicitly documents otherwise.
