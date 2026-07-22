# ADR 0001: Type-erased heterogeneous channel registry

## Status

Accepted (2026-07-21)

## Context

Applications register many channels with distinct `assigns`/`info` types,
resolved by topic at runtime. The coordinator must hold them in one
collection — a heterogeneous registry Gleam (no existentials, no type
classes) cannot express.

1. **Application-level variant type (Elm/Lustre style).** One app-supplied
   union type parameterizes everything. Type-safe, but it infects
   every public type (including the transport SPI), forces callbacks to
   match impossible variants, and adding a channel edits a global type,
   breaking open registration.

2. **Type erasure behind a typed facade (current design).** The registry
   stores a homogeneous `List(ChannelHandler)`; typed values are erased at
   registration and restored by closures from the same `register` call. The
   public API stays fully typed; erasure never leaks from `beryl.gleam`.

## Decision

Keep design 2. A Phoenix-shaped library is open-world — it cannot enumerate
application channel types — and erased internals behind typed facades are
an established Gleam/BEAM pattern: see [`gleam_otp`'s actor
`erase`](https://github.com/gleam-lang/otp/blob/v1.2.0/src/gleam/otp/actor.gleam#L518-L519),
[`gleam_erlang`'s
`unsafely_create_subject`](https://github.com/gleam-lang/erlang/blob/v1.3.0/src/gleam/erlang/process.gleam#L90),
and [`mist`'s `Dynamic` request
internals](https://github.com/rawhat/mist/blob/v6.0.3/src/mist/internal/http.gleam#L64).

Also make erasure closure-captured ("Option B"): a handler carries only
`join`; join returns a `JoinedChannel` — closures capturing the typed
assigns, each callback returning the next instance — so the coordinator
never sees erased assigns and per-callback identity-FFI coercions
disappear.

## Consequences

- Public API unchanged; the refactor is internal to `packages/beryl`.
- Two documented coercions remain: `send_info` erases the message and the
  joined closure restores it (sound — both come from one `register` call);
  connect-time assigns are seeded erased and restored unchecked — a
  pre-existing hole for a future ADR.
- Wire payloads stay `Dynamic` by design; decoders are a well-established
  boundary.
