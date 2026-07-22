# ADR 0001: Type-erased heterogeneous channel registry

## Status

Accepted (2026-07-21)

## Context

Applications register many channels with distinct `assigns`/`info` types.
Join requests carry client-chosen topic strings, so the coordinator selects
a channel at runtime by matching the topic against every registered pattern
(`State.handlers` in `coordinator.gleam`). That dispatch point sees channels
of differing types — heterogeneity Gleam (no existentials, no type classes)
cannot express.

1. **Application-level variant type (Elm/Lustre style).** One app-supplied
   union type parameterizes everything, so every public type — including
   the transport SPI — gains the parameters. Lustre shows this is livable
   when one author owns the whole message type, and nested wrapping
   (`element.map`) spares callbacks from matching impossible variants. But
   adding a channel still edits a shared type, ruling out registration of
   independently authored channels. Even Lustre erases behind its typed
   API ([vdom
   `coerce`](https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/vnode.gleam#L195-L197))
   and crosses component boundaries with `Dynamic` plus decoders
   ([`on_attribute_change`](https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/component.gleam#L118-L138)).

2. **Type erasure behind a typed facade (current design).** The registry
   stores a homogeneous `List(ChannelHandler)`; typed values are erased at
   registration and restored by closures from the same `register` call. The
   public API stays fully typed; erasure never leaks from `beryl.gleam`.

## Decision

Keep design 2. Beryl compiles before the application's channel types
exist, so it can never write their union itself — only the application
can, which is design 1's cost. Erased internals behind typed facades are
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
