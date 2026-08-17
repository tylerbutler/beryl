# ADR 0001: Type-erased heterogeneous channel registry

## Status

Superseded (2026-07-21) by [ADR 0002](0002-app-side-dispatch.md). ADR 0002
replaced the channel-module registry described below with app-side dispatch;
this document is retained for historical context on why type erasure was
chosen at the time and is no longer an accurate description of Beryl's
public API.

## Context

Beryl's unit of composition is the registered channel module, with dispatch
inside the library (Phoenix's shape): applications register channels with
distinct `assigns`/`info` types, and everything below follows from that
design decision. Join requests carry client-chosen topic strings, so the
coordinator selects a channel at runtime by matching the topic against
every registered pattern (`State.handlers` in `coordinator.gleam`). That
dispatch point sees channels of differing types — heterogeneity Gleam (no
existentials, no type classes) cannot express.

1. **Application-level variant type.** Keep library-side dispatch, but
   have the app supply one union type that parameterizes every public
   type, including the transport SPI. This borrows only half of the
   Elm/Lustre architecture: Lustre is fully type-safe because the app
   also owns dispatch — a parent model holds each child in a known field,
   and `element.map` tags messages where they are constructed. With
   dispatch inside beryl, the library can only hand each callback the
   whole union, so every callback handles variants that "cannot" occur —
   the unchecked cast reappears as app-visible boilerplate. Even Lustre
   erases internally ([vdom
   `coerce`](https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/vnode.gleam#L195-L197))
   and crosses component boundaries with `Dynamic` plus decoders
   ([`on_attribute_change`](https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/component.gleam#L118-L138)).

2. **App-side dispatch (fully Elm/Lustre).** Beryl delivers wire events to
   one app-written update function that routes topics itself. Fully
   type-safe, but per-channel lifecycle, authorization, rate limiting, and
   presence move into application code.

3. **Type erasure behind a typed facade (current design).** The registry
   stores a homogeneous `List(ChannelHandler)`; typed values are erased at
   registration and restored by closures from the same `register` call. The
   public API stays fully typed; erasure never leaks from `beryl.gleam`.

## Decision

Keep design 3. Beryl compiles before the application's channel types
exist, so it can never write their union itself — only the application
can, which is design 1's cost. Erased internals behind typed facades are
an established Gleam/BEAM pattern: see [`gleam_otp`'s actor
`erase`](https://github.com/gleam-lang/otp/blob/v1.2.0/src/gleam/otp/actor.gleam#L518-L519),
[`gleam_erlang`'s
`unsafely_create_subject`](https://github.com/gleam-lang/erlang/blob/v1.3.0/src/gleam/erlang/process.gleam#L90),
and [`mist`'s `Dynamic` request
internals](https://github.com/rawhat/mist/blob/v6.0.3/src/mist/internal/http.gleam#L64).

Also make erasure closure-captured ("Option B"): a handler carries only
`join`, which returns sealed callback closures capturing the typed
assigns, each callback returning the next instance — so the coordinator
never sees erased assigns and needs no per-callback coercions.

## Consequences

- Public API unchanged; the refactor is internal to `packages/beryl`.
- Two documented coercions remain: `send_info` erases the message and the
  joined closure restores it (sound — both come from one `register` call);
  connect-time assigns are seeded erased and restored unchecked — a
  pre-existing hole for a future ADR.
- Wire payloads stay `Dynamic` by design; decoders are a well-established
  boundary.
