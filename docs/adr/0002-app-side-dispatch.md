# ADR 0002: Single app-side dispatch model

## Status

Accepted (2026-07-21). Supersedes [ADR 0001](0001-type-erased-channel-registry.md).

Amended by [ADR 0003](0003-layered-channel-api.md) (accepted 2026-08-02),
which adds `beryl/channel`, an optional channel layer built entirely on this
ADR's public API. Every decision below remains in effect. App-side dispatch is
the core programming model, and the core contains no erasure. ADR 0003 adds
channel-module ergonomics above that API. Its location in `packages/beryl`
does not make it part of the runtime internals.

Amended (2026-08-17) to record the scalability ceiling of the current shared
runtime actor and the compatibility boundary for a post-1.0 process-topology
rewrite. The public dispatch model is unchanged.

## Context

ADR 0001 chose type erasure given library-side dispatch, and its analysis
identified two facts that require us to review that premise:

- App-side dispatch (ADR 0001's design 2) removes unchecked casts from the
  application dispatch path. The design removes the two remaining coercions
  that ADR 0001 documents. `send_info` becomes an ordinary typed `Subject(msg)`
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
ergonomics. This ADR replaces those ergonomics with soundness and one API. It
does not maintain two APIs, as the layered variant in ADR 0001 would require.

## Decision

Replace the channel-module API entirely with app-side dispatch:

- One supervised entry point, `beryl.child_spec(config, init, update)
  -> Result(#(Sockets, ChildSpecification(_)), ConfigError)`: the app
  supplies `init: fn(ConnectInfo(msg)) -> #(model, List(Effect))` and
  `update: fn(model, Input(msg)) -> Next(model)` for each socket. The app
  routes topics.
- Callback returns are an effects list (join acceptance/rejection, reply,
  push, broadcast, and topic kick), replacing the old channel API's
  one-action `HandleResult`. Presence effects are deferred to the later
  async presence slice; stopping a socket remains a `Next` result.
- Channel modules and the registry are removed, along with identity-FFI
  erasure from socket dispatch. The validated raw PubSub coercion boundary described
  above remains because Erlang `pg` delivers untyped mailbox terms.
- Third-party functionality ships as embeddable `model`/`msg`/`update`
  triples that apps connect with a wrapper variant. This is the composition
  pattern established by the Elm/Lustre ecosystem.
- Abuse controls are declarative per-topic-pattern config on `Config`,
  supplied to `child_spec`.
- Server-side sends to a joined socket go through a typed `Sender(msg)`
  (`beryl/socket.notify`) from `ConnectInfo.self`. This operation is an
  ordinary typed send and uses no erasure.

The shipped API is documented in the
[App-Side Dispatch guide](https://beryl.tylerbutler.com/guides/dispatch/) and
the generated [API reference](https://beryl.tylerbutler.com/reference/api/);
`beryl.gleam` and `beryl/socket.gleam` carry the authoritative signatures.

## Consequences

- This decision required a breaking rewrite of the `packages/beryl` public
  API, docs, and examples. Hex publishing was disabled during the cutover, so
  external migration cost was low. The change deleted the legacy pre-dispatch
  channel API (`beryl/channel`, `beryl/socket`, `beryl/coordinator`,
  `beryl/supervisor`) instead of deprecating it. ADR 0003 later reused the
  `beryl/channel` module name for its closure-sealed layer.
- The typed core stays behind a monomorphic frame-level SPI. Transports
  capture the exact runtime pid, monitor it, and atomically install the
  socket, closer, codec, and `ConnectSeed` with `admit_socket`.
- Union-and-router boilerplate increases linearly with the channel count.
  Single-channel apps have no such boilerplate because they use their types
  directly. ADR 0003's `beryl/channel` layer later removed that cost for
  multi-topic apps. An unreleased intermediate `beryl/socket/router` API was removed before
  release rather than becoming a third programming model.
- The effects type created the main join-acknowledgment ordering risk. Effects
  apply
  strictly in list order, so list order is wire order. The current runtime
  applies them within one actor turn, but the guarantee does not require that
  topology. Lane B handles presence separately. Synchronous presence work
  stays outside the shared runtime. The indivisible asynchronous read-model
  and effect bundle remains deferred to a later change.
- Supervision is explicit through the sole runtime entry point:
  `child_spec` returns the beryl subtree (runtime plus an optional
  connection limiter) for the caller's own supervisor. beryl owns only
  that subtree. beryl borrows supplied presence and PubSub handles and
  separately started groups. `stop` drains and terminates only the beryl
  subtree. It does not terminate the application's root or sibling processes.
  See
  [Supervision](/guides/supervision/) for the full contract, including what
  state is lost when the supervised runtime restarts.

## Scalability and post-1.0 compatibility

The current implementation runs every application's callbacks in one runtime
actor. This keeps state ownership and ordering simple, but it also serializes
all callback work for a channel system in one BEAM process. Therefore, only one
scheduler can run that work at a time. This design creates a known throughput
limit. The public programming model does not require this process topology.

The public compatibility boundary is:

- Each socket has one `model` and one `msg` type. Its `update` calls are
  serialized, each call receives the model returned by the previous call, and
  client inputs remain ordered for that socket.
- Effects from one `Next` are applied in list order, and that order is
  observable wire order. A later effect in the same list cannot overtake a
  join acknowledgment.
- No execution ordering is guaranteed between different sockets.
- Runtime process count, process identities, routing layout, and supervisor
  shape are implementation details. Public handles remain opaque.

These constraints permit a post-1.0 internal rewrite to a routing/registry
process with one supervised actor per socket. Different sockets could then run
callbacks on different schedulers while preserving the `init`/`update` API,
per-socket model semantics, input order, effects, refs, and wire behavior. A
busy socket would remain sequential by design. Topic-scoped crash
containment could continue inside that socket actor without making the process
layout observable.

One actor for each joined socket and topic pair has different tradeoffs. It
fits the private state owned by `beryl/channel`, but true parallel callback execution
across two topics on the same socket would change observable callback ordering
and cannot preserve raw dispatch's single per-socket model semantics. Such a
change requires a separate decision. It may require a major version unless the
relevant API excludes that ordering from its guarantees. One actor for all
subscribers to a topic name is not a suitable substitute. It couples unrelated
channel instances, makes a busy topic a bottleneck, and exposes all local
subscribers of that topic to one crash.

The public `stats.runtime_mailbox_length` metric currently exposes the
single-actor topology indirectly. Before 1.0 its meaning should be generalized
as a topology-independent dispatch backlog. Another option is to replace it
with separate router and worker backlog metrics. This change prevents
operational compatibility from blocking the rewrite.
