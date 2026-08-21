# ADR 0001: Type-erased heterogeneous channel registry

## Status

Superseded (2026-07-21) by [ADR 0002](0002-app-side-dispatch.md). ADR 0002
replaced the channel-module registry with app-side dispatch. We retain this
document to explain why we chose type erasure at the time. It does not describe
Beryl's current public API.

## Context

Beryl uses the registered channel module as its unit of composition. The
library dispatches events, as Phoenix does. Applications register channels
with distinct `assigns` and `info` types. The following problem results from
that design.

Join requests contain topic strings that clients choose. At runtime, the
coordinator matches each topic against all registered patterns
(`State.handlers` in `coordinator.gleam`) and selects a channel. The channels
at this dispatch point have different types. Gleam cannot express this
heterogeneity because it has no existential types or type classes.

1. **Application-level variant type.** Keep library-side dispatch, but
   require the app to supply one union type that parameterizes every public
   type, including the transport SPI. This borrows only half of the
   Elm/Lustre architecture. Lustre is fully type-safe because the app
   also owns dispatch. A parent model holds each child in a known field,
   and `element.map` tags messages where they are constructed. With
   dispatch inside beryl, the library can only hand each callback the
   complete union. Each callback must then handle variants that cannot
   occur. The unchecked cast becomes application-visible boilerplate. Lustre
   erases internally ([vdom
   `coerce`](https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/vnode.gleam#L195-L197))
   and crosses component boundaries with `Dynamic` plus decoders
   ([`on_attribute_change`](https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/component.gleam#L118-L138)).

2. **App-side dispatch (fully Elm/Lustre).** Beryl delivers wire events to
   one app-written update function. That function routes topics. This option
   is fully type-safe, but it moves the per-channel lifecycle, authorization,
   rate limiting, and presence into application code.

3. **Type erasure behind a typed facade (the design at the time).** The registry
   stores a homogeneous `List(ChannelHandler)`; typed values are erased at
   registration and restored by closures from the same `register` call. The
   public API remains fully typed. Erasure does not leave `beryl.gleam`.

## Decision

Keep design 3. Beryl compiles before the application's channel types exist,
so Beryl cannot define their union. Only the application can define it, which
creates the cost in design 1. Gleam and BEAM libraries use erased internals
behind typed facades. See [`gleam_otp`'s actor
`erase`](https://github.com/gleam-lang/otp/blob/v1.2.0/src/gleam/otp/actor.gleam#L518-L519),
[`gleam_erlang`'s
`unsafely_create_subject`](https://github.com/gleam-lang/erlang/blob/v1.3.0/src/gleam/erlang/process.gleam#L90),
and [`mist`'s `Dynamic` request
internals](https://github.com/rawhat/mist/blob/v6.0.3/src/mist/internal/http.gleam#L64).

Also capture erasure in closures ("Option B"). A handler contains only
`join`. This function returns sealed callback closures that capture the typed
assigns. Each callback returns the next instance. The coordinator does not
access erased assigns and does not need coercions for each callback.

## Consequences

- The public API does not change. The refactor affects only `packages/beryl`.
- Two documented coercions remain. `send_info` erases the message, and the
  joined closure restores it. This operation is sound because both functions
  come from one `register` call. Connect-time assigns start in erased form and
  use an unchecked restore. A future ADR must address this existing gap.
- Wire payloads remain `Dynamic` by design. Decoders form the validation
  boundary.
