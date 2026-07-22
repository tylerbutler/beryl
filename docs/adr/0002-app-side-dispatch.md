# ADR 0002: Single app-side dispatch model

## Status

Accepted (2026-07-21). Supersedes [ADR 0001](0001-type-erased-channel-registry.md).

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

## Decision

Replace the channel-module API entirely with app-side dispatch:

- One entry point, `beryl.start(config, init, update) -> Result(Sockets,
  StartError)` (and the embeddable `beryl.child_spec(config, init, update)
  -> Result(#(Sockets, ChildSpecification(_)), ConfigError)`): the app
  supplies `init: fn(ConnectInfo(msg)) -> #(model, List(Effect))` and
  `update: fn(model, Event(msg)) -> Next(model, msg)` per socket, and
  routes topics itself.
- Callback returns are an effects list (reply, push, broadcast, presence
  ops, stop), replacing the old channel API's one-action `HandleResult`.
- Channel modules, the registry, and all identity-FFI erasure are removed.
- Third-party functionality ships as embeddable `model`/`msg`/`update`
  triples that apps wire in with a wrapper variant — the composition
  pattern established by the Elm/Lustre ecosystem.
- Abuse controls are declarative per-topic-pattern config on `Config`,
  supplied at `start`/`child_spec`.
- Server-side sends to a joined socket go through a typed `Sender(msg)`
  (`beryl/event.notify`), obtained from `ConnectInfo.self` — an ordinary
  typed send, no erasure.

Final API, current-to-new mapping, and the resolution of every open
question below: [socket API reference](../design/app-side-dispatch-reference.md).

## Consequences

- Full breaking rewrite of the `packages/beryl` public API, docs, and
  examples. Hex publishing was disabled during the cutover, so external
  migration cost was low and the old channel API (`beryl/channel`,
  `beryl/socket`, `beryl/coordinator`, `beryl/supervisor`) was deleted
  rather than deprecated.
- Transports were unaffected in shape: the typed core sits behind the
  existing frame-level SPI via closures captured at `start`/`child_spec`.
  The SPI itself was later cut to a monomorphic `ConnectSeed` model
  (`beryl/transport`), independent of this ADR.
- Union-and-router boilerplate scales with channel count: zero for
  single-channel apps (use your types directly), linear otherwise.
- The effects type carried the main design risk (join-ack ordering,
  presence interplay). Both were resolved: effects apply strictly in list
  order within one runtime actor turn (so list order is wire order), and
  presence-affecting effects (`PushPresence`/`BroadcastPresence`) read
  presence state at apply time, after earlier `PresenceTrack`/
  `PresenceUntrack` effects in the same list. Every example app was
  rewritten onto app-side dispatch to validate the design at scale.
- Supervision is explicit at each entry point: `start` owns a standalone,
  detached Beryl subtree (runtime plus an optional connection limiter);
  `child_spec` embeds the same subtree as a child of the caller's own
  supervisor. Either way Beryl owns only its own subtree — supplied
  presence/PubSub handles and separately started groups are borrowed, and
  `stop` drains and terminates only the Beryl subtree, never the
  application's root or siblings. See
  [Supervision](/guides/supervision/) for the full contract, including
  what state is lost on an unsupervised runtime crash.
