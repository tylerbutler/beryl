# ADR 0002: Single app-side dispatch model

## Status

Accepted (2026-07-21). Supersedes [ADR 0001](0001-type-erased-channel-registry.md).

Amended by [ADR 0003](0003-layered-channel-api.md) (accepted 2026-08-02),
which adds `beryl/channel`, an optional channel layer built entirely on this
ADR's public API. Every decision below stands unchanged: app-side dispatch
remains the core programming model and the core still contains no erasure.
ADR 0003 layers channel-module ergonomics above that API; co-locating the
layer in `packages/beryl` does not move it into the runtime internals.

Amended (2026-08-17) to record the scalability ceiling of the current shared
runtime actor and the compatibility boundary for a post-1.0 process-topology
rewrite. The public dispatch model is unchanged.

## Context

ADR 0001 chose type erasure given library-side dispatch, and its analysis
surfaced two facts that motivate revisiting that premise:

- App-side dispatch (ADR 0001's design 2) removes unchecked casts from the
  application dispatch path. The two residual coercions ADR 0001 documents
  close structurally: `send_info` becomes an ordinary typed `Subject(msg)`
  send, and connect-time assigns disappear because the app's `init` produces
  the model. A separate package-internal boundary remains in PubSub:
  `pg` delivers frozen raw `Message(payload)` records to a process mailbox,
  so `pubsub.selecting` first validates the record tag and four-field arity,
  then uses the retained identity FFI to recover the subscriber's
  compile-time payload type.
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

- One supervised entry point, `beryl.child_spec(config, init, update)
  -> Result(#(Sockets, ChildSpecification(_)), ConfigError)`: the app
  supplies `init: fn(ConnectInfo(msg)) -> #(model, List(Effect))` and
  `update: fn(model, Input(msg)) -> Next(model)` per socket, and
  routes topics itself.
- Callback returns are an effects list (join acceptance/rejection, reply,
  push, broadcast, and topic kick), replacing the old channel API's
  one-action `HandleResult`. Presence effects are deferred to the later
  async presence slice; stopping a socket remains a `Next` result.
- Channel modules and the registry are removed, along with identity-FFI
  erasure from socket dispatch. The validated raw PubSub coercion boundary described
  above remains because Erlang `pg` delivers untyped mailbox terms.
- Third-party functionality ships as embeddable `model`/`msg`/`update`
  triples that apps wire in with a wrapper variant — the composition
  pattern established by the Elm/Lustre ecosystem.
- Abuse controls are declarative per-topic-pattern config on `Config`,
  supplied to `child_spec`.
- Server-side sends to a joined socket go through a typed `Sender(msg)`
  (`beryl/socket.notify`), obtained from `ConnectInfo.self` — an ordinary
  typed send, no erasure.

The shipped API is documented in the
[App-Side Dispatch guide](https://beryl.tylerbutler.com/guides/dispatch/) and
the generated [API reference](https://beryl.tylerbutler.com/reference/api/);
`beryl.gleam` and `beryl/socket.gleam` carry the authoritative signatures.

## Consequences

- Full breaking rewrite of the `packages/beryl` public API, docs, and
  examples. Hex publishing was disabled during the cutover, so external
  migration cost was low and the legacy pre-dispatch channel API
  (`beryl/channel`,
  `beryl/socket`, `beryl/coordinator`, `beryl/supervisor`) was deleted
  rather than deprecated. ADR 0003 later reused the `beryl/channel` module
  name for its closure-sealed layer.
- The typed core stays behind a monomorphic frame-level SPI. Transports
  capture the exact runtime pid, monitor it, and atomically install the
  socket, closer, codec, and `ConnectSeed` with `admit_socket`.
- Union-and-router boilerplate scales with channel count: zero for
  single-channel apps (use your types directly), linear otherwise. ADR 0003's
  `beryl/channel` layer later absorbed that cost for multi-topic apps. An
  unreleased intermediate `beryl/socket/router` API was removed before
  release rather than becoming a third programming model.
- The effects type carried the main join-ack ordering risk. Effects apply
  strictly in list order, so list order is wire order. The current runtime
  does this within one actor turn, but that topology is not part of the
  guarantee. Presence integration is deliberately separate in Lane B:
  synchronous presence work stays outside the shared runtime, while the
  indivisible async read-model/effect bundle is deferred to a later slice.
- Supervision is explicit through the sole runtime entry point:
  `child_spec` returns the Beryl subtree (runtime plus an optional
  connection limiter) for the caller's own supervisor. Beryl owns only
  that subtree — supplied
  presence/PubSub handles and separately started groups are borrowed, and
  `stop` drains and terminates only the Beryl subtree, never the
  application's root or siblings. See
  [Supervision](/guides/supervision/) for the full contract, including what
  state is lost when the supervised runtime restarts.

## Scalability and post-1.0 compatibility

The current implementation runs every application's callbacks in one runtime
actor. This keeps state ownership and ordering simple, but it also serializes
all callback work for a channels system onto one BEAM process and therefore one
scheduler at a time. That is a known throughput ceiling, not a required part
of the public programming model.

The public compatibility boundary is:

- Each socket has one `model` and one `msg` type. Its `update` calls are
  serialized, each call receives the model returned by the previous call, and
  client inputs remain ordered for that socket.
- Effects from one `Next` are applied in list order, and that order is
  observable wire order. A join acknowledgement cannot be overtaken by a later
  effect in the same list.
- No execution ordering is guaranteed between different sockets.
- Runtime process count, process identities, routing layout, and supervisor
  shape are implementation details. Public handles remain opaque.

These constraints permit a post-1.0 internal rewrite to a routing/registry
process with one supervised actor per socket. Different sockets could then run
callbacks on different schedulers while preserving the `init`/`update` API,
per-socket model semantics, input order, effects, refs, and wire behavior. A
busy individual socket would remain sequential by design. Topic-scoped crash
containment could continue inside that socket actor without making the process
layout observable.

One actor per joined socket/topic pair is a different trade-off. It fits the
private state owned by `beryl/channel`, but true parallel callback execution
across two topics on the same socket would change observable callback ordering
and cannot preserve raw dispatch's single per-socket model semantics. Such a
change requires a separate decision and may require a major version unless the
affected ordering is explicitly outside the relevant API's guarantees. One
actor shared by all subscribers to a topic name is not a suitable substitute:
it couples unrelated channel instances, makes a hot topic a bottleneck, and
widens a crash to every local subscriber of that topic.

The public `stats.runtime_mailbox_length` metric currently exposes the
single-actor topology indirectly. Before 1.0 its meaning should be generalized
to a topology-independent dispatch backlog, or replaced with separately named
router and worker backlog metrics, so operational compatibility does not block
this rewrite.
