# ADR 0002: Single app-side dispatch model

## Status

Proposed (2026-07-21). Supersedes [ADR 0001](0001-type-erased-channel-registry.md)
if accepted.

## Context

ADR 0001 chose type erasure given library-side dispatch, and its analysis
surfaced two facts that motivate revisiting that premise:

- App-side dispatch (ADR 0001's design 2) is the only considered design
  with no unchecked casts anywhere — including the two residual coercions
  ADR 0001 documents, which close structurally: `send_info` becomes an
  ordinary typed `Subject(msg)` send, and connect-time assigns disappear
  because the app's `init` produces the model.
- Nearly all library infrastructure keys on topic strings and wire data,
  not app types: rate limiting, connection limits, presence, pubsub, and
  the wire codec stay library-side under either model. The transport SPI
  is already frame-level and carries no app types, so `beryl_mist` and
  `beryl_ewe` are unaffected.

Phoenix compatibility is a wire-protocol property (`phx_join`, refs,
heartbeats, `presence_state`/`presence_diff`); clients cannot observe the
server-side programming model. ADR 0001 kept channel modules for their
ergonomics. This ADR proposes trading those ergonomics for soundness and a
single API, rather than maintaining two APIs (the layered variant ADR 0001
deferred).

## Decision (proposed)

Replace the channel-module API entirely with app-side dispatch:

- One entry point, roughly `beryl.start(config, init, update)`: the app
  supplies `init: fn(ConnectInfo) -> model` and
  `update: fn(model, Event(msg)) -> Next(model, msg)` per socket, and
  routes topics itself.
- Callback returns become an effects list (reply, push, broadcast,
  presence ops, stop), replacing today's one-action `HandleResult`.
- Channel modules, the registry, and all identity-FFI erasure are removed.
- Third-party functionality ships as embeddable `model`/`msg`/`update`
  triples that apps wire in with a wrapper variant — the composition
  pattern established by the Elm/Lustre ecosystem.
- Abuse controls become declarative per-topic-pattern config at `start`.

API strawman, current-to-new mapping, and open questions:
[socket-api-strawman](../design/socket-api-strawman.md).

## Consequences

- Full breaking rewrite of the `packages/beryl` public API, docs, and
  examples. Hex publishing is currently disabled, so external migration
  cost is low today and grows with every release under the old model.
- Transports are unaffected; the typed core sits behind the existing
  frame-level SPI via closures captured at `start`.
- Union-and-router boilerplate scales with channel count: zero for
  single-channel apps (use your types directly), linear otherwise.
- The effects type is the main design risk (join-ack ordering, presence
  interplay). Acceptance gate: the strawman survives those cases and one
  real example app is rewritten to gauge boilerplate at scale.
