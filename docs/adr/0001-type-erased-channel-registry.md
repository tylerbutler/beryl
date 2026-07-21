# ADR 0001: Type-erased heterogeneous channel registry

## Status

Accepted (2026-07-21)

## Context

Beryl lets applications register many channels, each with its own `assigns`
and `info` types (`Channel(assigns, info)`), under topic patterns resolved at
runtime. The coordinator must hold all registered channels in one collection
and dispatch wire events to whichever channel matches — a heterogeneous
registry, which Gleam's type system (no existential types, no type classes)
cannot express directly.

Two designs were considered:

1. **Application-level variant type (Elm/Lustre style).** Parameterize the
   whole system by a single app-supplied type: `Channels(assigns, info)`,
   with applications defining `type AppAssigns { ChatAssigns(..) RoomAssigns(..) }`.
   Fully type-safe with zero coercion, but the parameters infect every public
   type — including the transport SPI, so `beryl_mist`/`beryl_ewe` become
   generic over types they never inspect. Every channel callback receives the
   union type and must pattern-match away variants that cannot occur for that
   channel, trading unsafe coercion for compiler-mandated dead code. Adding a
   channel means editing a global type, breaking Phoenix-style open
   registration of independent channels from independent modules.

2. **Type erasure behind a typed facade (current design).** The registry
   stores a homogeneous `List(ChannelHandler)` of closures; typed values are
   erased at registration and restored inside closures created by the same
   `register` call. The public API stays fully typed
   (`Channel(assigns, info)`, `RegisteredChannel(assigns, info)`,
   `send_info`), and erasure never leaks out of `beryl.gleam`.

## Decision

Keep design 2: an open, heterogeneous registry with erasure confined to the
`beryl.gleam` / `coordinator` boundary.

A Phoenix-shaped channel library is inherently open-world — the library
cannot enumerate application channel types, and channels must be addable
without touching a shared type. Erased internals behind typed facades are
also the established pattern for BEAM framework code in Gleam (`gleam_otp`
actors, `mist` handlers, `process.Selector`); the community norm this
satisfies is that unsafe coercion must never appear in the public API, not
that it must never exist.

Additionally, tighten the encoding so erasure is closure-captured rather than
value-round-tripped ("Option B"):

- A registered `ChannelHandler` carries only `join`. A successful join
  returns a `JoinedChannel` instance — a record of closures that capture the
  channel's current **typed** assigns. Each callback returns the *next*
  instance, so assigns threading is compiler-checked inside `beryl.gleam`;
  the coordinator stores instances (`Dict(String, JoinedChannel)`) and never
  sees an erased assigns value.
- This removes the identity-FFI coercions previously performed on every
  callback (`unsafe_coerce_socket`, assigns → `Dynamic`).

## Consequences

- Public API unchanged; the refactor is internal to `packages/beryl`.
- Two narrow, documented coercions remain:
  - **`info` messages**: `send_info` erases the message; the joined
    instance's closure restores it. Sound because the coordinator dispatches
    only when the joined channel's id equals the `RegisteredChannel` handle's
    id, and both the handle and the instance derive from the same `register`
    call.
  - **Connect-time assigns**: transports seed socket assigns type-erased,
    and join restores them to the channel's assigns type unchecked. This is a
    pre-existing hole (a transport can seed a type no channel expects) and is
    **not** fixed here; making it explicit (e.g. join receiving `Dynamic`
    connect assigns plus a decoder) is a deliberate public-API change left to
    a future ADR.
- Wire payloads remain `Dynamic` by design: data from the network is
  genuinely dynamic, and decoders are the idiomatic boundary.
