# PubSub typed actor replacement plan

## Status

Implemented. The membership state and recovery policy now live in a typed
Gleam actor. The Erlang supervisor remains because the current `gleam_otp`
factory supervisor does not provide the keyed, concurrent dynamic-child
contract used for lazy PubSub scopes.

## Objective

Replace `beryl_pubsub_memberships.erl` with a typed Gleam actor while
preserving beryl's current PubSub API, distributed wire format, failure
behavior, and `pg` recovery guarantees.

Remove Erlang source when Gleam and `gleam_otp` provide a clear equivalent.
Keep a small Erlang boundary when direct BEAM interop is easier to understand
and maintain than a larger Gleam workaround.

Do not adopt `group_registry`. Its duplicate-join semantics, lost memberships
after registry restart, lack of local-member queries, generated scope names,
and subject message shape do not satisfy beryl's existing contracts.

## Scope

### In scope

- Replace the membership `gen_server` with an internal typed actor.
- Keep one authoritative local membership set per PubSub scope.
- Restore live local memberships after the scope's `pg` process restarts.
- Keep joins and leaves idempotent per owner, scope, and topic.
- Remove memberships when their local owner exits.
- Preserve existing handles through a `pg` restart.
- Invalidate existing handles when the membership actor is lost.
- Preserve distributed and local member queries.
- Preserve the frozen five-element broadcast tuple.
- Move simple `pg` calls and raw sends to direct Gleam external declarations
  when their types are clear.
- Evaluate whether the existing Erlang supervisors can move to Gleam without
  making lazy, concurrent scope startup harder to understand.
- Retain all current PubSub recovery and contract tests.

### Not in scope

- Change the public `beryl/pubsub` API.
- Change PubSub delivery from best-effort to guaranteed delivery.
- Buffer or replay broadcasts during recovery.
- Persist memberships across node restart or membership-actor loss.
- Change the distributed wire tuple or encode payloads.
- Replace Erlang distribution or OTP `pg`.
- Adopt `group_registry` or add another PubSub dependency.
- Generalize the actor into a reusable registry package.

## Required behavior

The current code and tests define the migration contract.

1. `start` creates or attaches to a node-owned service for one static scope.
2. The service outlives the process that first calls `start`.
3. Concurrent starts for one scope return handles for the same membership
   actor.
4. An externally started, unmanaged `pg` process with the same scope is a
   startup conflict. beryl must not adopt or stop it.
5. A subscriber owner has at most one membership for each topic, even after
   repeated or concurrent joins through different handles.
6. One leave removes that owner's logical membership for the topic.
7. Repeated leaves are harmless and do not affect other topics, owners, or
   scopes.
8. The membership actor monitors every local owner and removes its recovery
   intent after that owner exits.
9. If `pg` restarts, the membership actor rejoins every live local owner to
   every recorded topic.
10. A join or leave received during recovery updates the authoritative intent
    before it reports that the scope is unavailable. A retry is safe.
11. Existing handles remain valid after only `pg` restarts.
12. If the membership actor is lost, its replacement starts with no
    memberships and old handles remain invalid.
13. Global queries use `pg:get_members`. Local queries use
    `pg:get_local_members`.
14. Broadcasts during recovery can be lost and are not replayed.
15. Every broadcast arrives as:

    ```text
    {Scope, Topic, Event, Payload, From}
    ```

    The scope atom and the four `Message` fields form one flat five-element
    tuple. A Gleam `Subject` wrapper must not add another tuple layer.

The existing coverage in
`packages/beryl/test/pubsub_test.gleam` and
`packages/beryl/test/beryl_pubsub_test_ffi.erl` must continue to pass.

## Target layout

Use small modules with one responsibility:

```text
packages/beryl/src/
├── beryl/
│   ├── pubsub.gleam
│   ├── pubsub_memberships.gleam
│   └── pubsub_native.gleam
├── beryl_pubsub_supervisor.erl
└── beryl_pubsub_ffi.erl
```

During the first phase:

- `pubsub_memberships.gleam` owns the actor, state, recovery, and typed
  messages.
- `pubsub_native.gleam` contains direct external declarations for small OTP
  operations that can be typed safely.
- `beryl_pubsub_supervisor.erl` remains responsible for the node-wide root and
  per-scope supervision.
- `beryl_pubsub_ffi.erl` is reduced to startup and compatibility operations
  that still need Erlang terms or supervisor APIs.

After the actor is stable, evaluate moving the supervisors to:

```text
packages/beryl/src/beryl/pubsub_supervisor.gleam
```

Delete the Erlang supervisor only if the Gleam version preserves detached
node ownership, concurrent lazy startup, dynamic scopes, child order, and
restart strategy with less or equally clear code.

## Typed actor design

### Actor handle

The internal handle should contain the actor's typed subject:

```gleam
pub opaque type Registry {
  Registry(subject: process.Subject(Message))
}
```

`beryl/pubsub.PubSub` and `Subscriber` should store this handle instead of a
bare registry PID. Because the subject is PID-backed, it continues to address
the same actor through a `pg` restart and remains invalid after the actor dies.

Do not use a name-backed subject for public handles. A name-backed subject
would silently address a replacement membership actor after registry loss,
which would violate the current handle-generation contract.

### Messages

Use opaque actor messages. Suggested shapes:

```gleam
pub opaque type Message {
  Ready(reply: process.Subject(Result(Nil, RegistryError)))
  Join(
    topic: String,
    owner: process.Pid,
    reply: process.Subject(Result(Nil, RegistryError)),
  )
  Leave(
    topic: String,
    owner: process.Pid,
    reply: process.Subject(Result(Nil, RegistryError)),
  )
  ProcessDown(process.Down)
  Recover
}
```

`Ready`, `Join`, and `Leave` are synchronous actor calls. `ProcessDown`
receives monitor notifications for both subscriber owners and the current
`pg` process. `Recover` retries after startup or a failed replay.

Do not expose these messages outside the package.

### Errors

Use a small internal error type:

```gleam
pub type RegistryError {
  ScopeRecovering
  PgUnavailable(reason: Dynamic)
}
```

The actor must return errors as data. `beryl/pubsub` can then preserve the
current public exit behavior at its compatibility boundary. Prefer a direct
external declaration for `erlang:exit/1` over a custom Erlang function if the
signature can be expressed safely.

Do not turn an unavailable actor or failed `pg` operation into an empty member
list. A success-shaped fallback would hide service loss.

### State

Suggested state:

```gleam
type State {
  State(
    scope: atom.Atom,
    self: process.Subject(Message),
    owners: Dict(process.Pid, Owner),
    pg: Option(PgGeneration),
    retry: Option(process.Timer),
  )
}

type Owner {
  Owner(
    monitor: process.Monitor,
    topics: Set(String),
  )
}

type PgGeneration {
  PgGeneration(
    pid: process.Pid,
    monitor: process.Monitor,
  )
}
```

`owners` is the authoritative recovery set. `pg` records the generation that
has received a complete replay. `retry` prevents more than one recovery timer
from being active.

If Gleam collections cannot use `process.Pid` as a `Dict` key, use a list of
owner records first. Membership sets are expected to remain small. Do not add
an ETS index without measured need.

### Selector

Build one selector that receives:

- the actor subject;
- all process monitor messages; and
- recovery timer messages through the actor subject.

Use `process.select_monitors` so owner and `pg` monitors can be added after
actor initialization. Identify a down process by comparing both its PID and
monitor with the stored generation or owner record.

## Operations

### Start and readiness

The existing supervisor starts the membership actor before `pg`. Actor
initialization must therefore complete without waiting for `pg`.

On initialization:

1. Store an empty owner map.
2. Set the `pg` generation to `None`.
3. Schedule `Recover`.
4. Return the actor subject to the supervisor.

`Ready` calls `synchronise` before replying. Startup succeeds only after the
actor finds the managed `pg` process and completes a stable replay.

### Join

For `Join(topic, owner, reply)`:

1. If the owner is new, monitor it and create an empty topic set.
2. Add the topic to the owner's set. Adding an existing topic changes nothing.
3. Run `synchronise`.
4. If the scope is ready, call `join_once`.
5. Reply with `Ok(Nil)` or the recovery error.

Record intent before touching `pg`. If `pg` is unavailable, the failed call
can still take effect after recovery. Retrying remains idempotent.

`join_once` must check `pg:get_local_members` before calling `pg:join`.
Although the owner map is a set, this check also prevents duplicate entries
after uncertain failures.

### Leave

For `Leave(topic, owner, reply)`:

1. Remove the topic from the owner's set.
2. If no topics remain, demonitor the owner and remove its record.
3. Run `synchronise`.
4. If the scope is ready, call `pg:leave`.
5. Reply with `Ok(Nil)` or the recovery error.

Record the removal before touching `pg`. A recovery replay must therefore not
restore a membership that a failed leave intended to remove.

### Owner exit

When a subscriber owner exits:

1. Match the PID and monitor against `owners`.
2. Remove the owner record.
3. Do not call `pg:leave`; `pg` removes dead members itself.

Ignore stale monitor messages that do not match the stored monitor.

### `pg` exit

When the monitored `pg` process exits:

1. Clear the `pg` generation.
2. Schedule one `Recover` message.
3. Keep the owner map unchanged.

Joins and leaves can continue to update intent while the scope is recovering,
but they report an error until a replacement generation has received a stable
replay.

### Recovery

`synchronise` must:

1. Resolve the process registered under the configured scope.
2. Reject a missing process as `ScopeRecovering`.
3. If it is already the current ready generation, run the requested operation.
4. Otherwise replay every topic for every live local owner with `join_once`.
5. Confirm that the registered scope PID is still the same live process after
   replay.
6. Monitor the stable generation and mark it ready.
7. Run the requested operation.

If the process changes during replay, discard that generation and schedule
another retry. Never mark a partially replayed generation ready.

Before replaying an owner, check `process.is_alive`. Dead owners can be removed
from the next state instead of being rejoined.

## Native boundary

### Gleam native wrappers

Use direct external declarations in `pubsub_native.gleam` where the native
operation cannot raise an error that the actor must recover from:

- `pg:get_members/2`
- `pg:get_local_members/2`
- `erlang:send/2`

Keep small Erlang `try_pg_*` adapters for `pg:join/3`, `pg:leave/3`, and the
actor's local-member check. Gleam has no exception-catching construct, and a
direct call would crash the membership actor instead of returning the typed
recovery error. Do not expose raw return values or `Dynamic` beyond the native
module and actor error type.

Use `erlang:send/2` to send the flat five-element wire tuple. Do not use
`process.send`, because it wraps the value with a subject tag.

### Erlang retained during phase 1

Keep only operations that are clearer at the OTP boundary:

- atomically start or attach to the node-wide root supervisor;
- dynamically start or find a per-scope supervisor;
- query the membership child during scope startup;
- start the scoped `pg` process if its child specification cannot be expressed
  clearly through `gleam_otp`;
- convert failing `pg` mutations into `Result` values;
- rebuild the typed `Message` record after a selector matches the flat scoped
  wire tuple.

The retained Erlang must be small and mechanical. It must not own membership
state, retry policy, owner monitors, or replay logic.

## Supervision

### Phase 1 supervision

Keep the current tree:

```text
beryl PubSub root supervisor
└── scope supervisor
    ├── typed membership actor
    └── pg scope process
```

Keep `rest_for_one` ordering. A membership-actor restart also replaces `pg`,
which gives the new actor an empty scope. A `pg` restart leaves the actor and
its authoritative owner map alive.

The scope supervisor must keep the existing restart tolerance of five restarts
in ten seconds.

### Phase 2 supervision decision

After phase 1 passes all tests, prototype the same tree with `gleam_otp`.
Accept the Gleam replacement only if it provides all of these properties:

- the node-wide root does not inherit the first caller's lifetime;
- concurrent `start` calls converge on one root and one scope child;
- scopes can be added dynamically;
- the membership actor starts before `pg`;
- a `pg` restart does not restart the actor;
- an actor restart also replaces `pg`;
- old actor subjects stay invalid after actor replacement;
- unmanaged scope conflicts remain detectable;
- code size and failure paths are no harder to understand than the Erlang
  supervisor.

If these conditions require custom startup protocols or unsafe type coercions,
keep the Erlang supervisor. It is an acceptable small OTP interop boundary.

## Public API integration

Keep all public types and function signatures in `beryl/pubsub.gleam`.

Change only the internal handle:

```gleam
pub opaque type PubSub(payload) {
  PubSub(scope: atom.Atom, registry: pubsub_memberships.Registry)
}

pub opaque type Subscriber(payload) {
  Subscriber(
    scope: atom.Atom,
    registry: pubsub_memberships.Registry,
    owner: process.Pid,
  )
}
```

Route `join` and `leave` through typed actor calls. Keep member queries as
direct `pg` operations guarded by a registry-generation check, so a dead
registry handle cannot silently query a replacement scope.

Keep `selecting` unchanged. It must continue to select a record tagged by the
scope atom with four remaining fields.

## Migration phases

### Phase 1: establish the native wrapper

1. Add `beryl/pubsub_native.gleam`.
2. Move member queries, `pg` join/leave calls, raw sends, and the safe identity
   coercion behind typed Gleam wrappers.
3. Keep startup and membership mutation routed through the existing Erlang
   server.
4. Run the focused PubSub tests and `just beam-check`.

This phase proves the direct external signatures before actor behavior also
changes.

### Phase 2: add the typed membership actor

1. Add `beryl/pubsub_memberships.gleam`.
2. Implement owner state, typed calls, monitor selection, and recovery.
3. Change the scope supervisor to start the Gleam actor.
4. Change `beryl/pubsub` handles to store the actor registry.
5. Keep the old Erlang membership module until parity tests pass.
6. Run recovery tests repeatedly to expose mailbox and timing races.

### Phase 3: remove the Erlang membership server

1. Delete `beryl_pubsub_memberships.erl`.
2. Remove membership calls and state handling from `beryl_pubsub_ffi.erl`.
3. Update Xref and FFI checks.
4. Confirm the package contains no obsolete module references.

### Phase 4: evaluate Gleam supervision

1. Prototype the root and scope supervision tree with `gleam_otp`.
2. Test concurrent startup, detached lifetime, unmanaged conflicts, actor
   replacement, and restart ordering.
3. Delete `beryl_pubsub_supervisor.erl` only if the prototype meets every
   phase 2 supervision condition.
4. Otherwise keep the Erlang supervisor and document why it is the remaining
   OTP boundary.

### Phase 5: clean up tests and documentation

1. Replace test-only Erlang helpers with Gleam helpers where process APIs are
   available.
2. Keep Erlang helpers for `sys:suspend`, direct process dictionaries, and
   forced OTP child failures when Gleam wrappers would obscure the test.
3. Update `beryl/pubsub` module documentation only if implementation details
   changed. Do not weaken or remove the documented recovery guarantees.
4. Run generated reference documentation after any `////` or `///` changes.

## Test plan

### Existing tests that must remain

- Scope recovery restores live memberships.
- Recovery keeps scopes isolated.
- Joins and leaves during an outage update intent in order.
- Registry loss invalidates old handles.
- Concurrent starts share one membership actor.
- Repeated and concurrent joins remain idempotent.
- Repeated leaves preserve other owners, topics, and scopes.
- Global and local broadcasts reach the correct members.
- `broadcast_from` and socket exclusion preserve sender filtering.
- The raw broadcast tuple keeps the scope tag and flat arity.
- Selectors discriminate payload types by scope.

### Add focused actor tests

- A dead owner is removed from the owner map before replay.
- A stale owner monitor cannot remove a new record for the same PID.
- A stale `pg` monitor cannot clear a newer ready generation.
- Multiple recovery triggers schedule one retry timer.
- A `pg` replacement during replay is never marked ready.
- Join intent survives a failed `pg` operation.
- Leave intent is not restored after a failed `pg` operation.
- Actor loss starts an empty replacement and leaves old subjects invalid.

Use exact mailbox selectors. Every test must consume the messages and monitor
notifications it creates.

### Validation

Run:

```bash
cd packages/beryl
gleam test -- --filter "pubsub"
cd ../..
just format-check
just check
just test beryl
just lint
just beam-check
```

Run the focused recovery tests repeatedly before the full suite. The behavior
depends on process ordering and mailbox state, so one passing run is not enough
evidence for race-sensitive changes.

## Risks and controls

### Actor-call failure shape changes

`process.call` and the current `gen_server:call` do not fail with identical
terms. Keep actor errors as typed data and map them at the public compatibility
boundary. Add tests for unavailable and timed-out calls before deleting the old
FFI path.

### Duplicate `pg` membership

An uncertain `pg:join` can succeed before reporting failure. Always use
`join_once` during normal mutation and replay. Keep the owner topic collection
as a set.

### Mixed `pg` generations

A replacement can die while replay is in progress. Compare the registered PID
before and after replay and monitor only the stable generation.

### Stale monitor messages

PIDs and monitor messages can outlive the state that created them. Match the
stored monitor as well as the PID before changing state.

### Supervision rewrite grows larger than the Erlang boundary

Do not remove Erlang only to reproduce `supervisor:start_child`,
`which_children`, and detached startup through a custom protocol. Stop after
phase 3 if the remaining supervisor is smaller and clearer than the Gleam
replacement.

### Wire-format drift

Gleam subjects wrap messages as `{Tag, Message}`. The PubSub contract requires
one flat tuple. Keep a raw-send test that fails if an extra tuple layer is
introduced.

## Completion criteria

The migration is complete when:

- membership intent and recovery are implemented in a typed Gleam actor;
- `beryl_pubsub_memberships.erl` is deleted;
- all current public APIs and documented behaviors are unchanged;
- the five-element distributed wire tuple is unchanged;
- `pg` restarts preserve live local memberships and existing handles;
- membership-actor loss invalidates old handles and starts empty;
- joins and leaves remain idempotent;
- the remaining Erlang PubSub code, if any, contains only small OTP startup or
  supervision adapters;
- focused recovery tests, package tests, lint, and BEAM checks pass.
