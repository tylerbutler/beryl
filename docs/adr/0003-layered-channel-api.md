# ADR 0003: Layered channel API on the dispatch core

## Status

Accepted (2026-08-02). Amends [ADR 0002](0002-app-side-dispatch.md): the
dispatch core and its soundness guarantees do not change. This ADR restores
the channel-module ergonomics that ADR 0002 removed. It adds them as a layer
on the public API. ADR 0001 anticipated this outcome: "a
layered variant (typed core with channels as sugar on top) may merit a
future ADR."

Amended (2026-08-16): the layer was first implemented as the unreleased
`beryl_channels` package, but no tag or GitHub release ever contained it.
Before release, its public API moved to `beryl/channel` in the core `beryl`
package and the separate package was deleted. The package-boundary change
does not change the closure-sealing, generation-scoping, or zero-coercion
guarantees in this ADR.

## Context

ADR 0002 replaced the channel-module API with app-side dispatch, gaining
full type safety and a single core API at the cost of the channel module as
the unit of composition. Channel modules provided colocated callbacks,
removed the need for a hand-written union or router, and let applications use
third-party channels without app-side wiring. ADR 0002 treated the
models as alternatives because both models competed to be the core.

The core can support both models. Its entry point uses `init:
fn(ConnectInfo(msg)) -> #(model, List(Effect))` and `update: fn(model,
Input(msg)) -> Next(model)` (`beryl.child_spec`). This interface can host a
channel framework above the core as ordinary data. The framework can use
the closure-captured existential encoding that ADR 0001 already
validated ("Option B",
[#217](https://github.com/tylerbutler/beryl/pull/217)).

Interoperation between the two models is a non-goal: an application picks
raw dispatch or the channel layer per socket endpoint. (Nesting the layer
inside a larger `update` is possible because the router is an embeddable
`model`/`msg`/`update` triple. However, the public API does not support this
use.)

## Decision

Ship `beryl/channel` in the `beryl` package. Its implementation is built
only on beryl's public core API. Keep its routing machinery private:

- The entry point mirrors the supervised core:
  `channel.child_spec(config, handlers)`. It composes the handler
  list into an `#(init, update)` pair and delegates to
  `beryl.child_spec`. The layer uses the core `Config`, including declarative
  per-topic abuse controls, without changes. The layer does not restore an
  unsupervised start path.
- A handler pairs a topic pattern with a typed `join` callback. The layer
  owns the socket-level model, so `join` receives a layer-built
  `channel.JoinContext(info)`: socket id, transport seed, a scoped typed
  sender, concrete topic, wildcard captures, and join payload, instead of
  the core `ConnectInfo` itself. It answers with a rejection or
  `channel.accept(state, callbacks)`, which seals the typed state inside
  message, binary, info, and terminate closures. No channel state value is
  erased. Closures encode all heterogeneity.
- The router's model is the handler table plus one live sealed channel per
  joined topic; its `update` matches each `Input` by topic to the owning
  instance. The parsed matching pattern is reused to compute wildcard
  captures once. Channel callbacks return ordered lists of opaque,
  phase-typed actions that lower onto core `Effect` values in list order.
  A join's accept-time actions (`channel.with_actions`) lower strictly
  after the acknowledgment. Therefore, the socket is already subscribed and a
  push cannot overtake its own join reply. Asynchronous core effects may
  pause that socket while other sockets continue. The runtime resumes its
  remaining actions in order after the effect completes.
  `on_terminate` returns `List(Action(Closing))`, so only broadcasts,
  presence untracking, and presence broadcasts can be requested after the
  instance is removed. Pushes, replies, and presence tracking are
  active-phase operations and cannot be returned there.
- The layer owns the socket-level `msg` type, and it carries no typed
  value: a socket message is an envelope stamped with a topic and a
  per-socket monotonic join generation, wrapping one sealed `Mail`.
  `channel.notify` seals the typed value in a closure that only the join
  that created it can open. Before the router unseals any data, it compares
  the stamp with the live instance. The router drops sealed mail for a
  superseded or ended join. Channel and socket dispatch do not erase data to
  `Dynamic`. Therefore, they do not need the sound one-registration
  erase/restore pair that ADR 0001 documented for `send_info`.
- The design also removes ADR 0001's remaining unchecked channel and socket
  dispatch coercion: connect-time assigns that start erased and use an
  unchecked restore. A channel creates its state inside `join` and seals it in
  `channel.accept`, so there is no pre-join erased seed to restore.

## Consequences

- ADR 0002's core API and its channel/socket dispatch soundness guarantees
  remain unchanged; restoration happens in a public module layered on that
  API. The runtime design does not revert. The separate,
  validated PubSub boundary also remains: `pubsub.selecting` checks the raw
  `pg` message's record tag and arity before using the retained identity FFI
  to recover `Message(payload)`.
- The layer is the first internal use of ADR 0002's composition model. The
  complete channel framework is an embeddable triple assembled from the
  public API. If the layer cannot access a required capability, the core
  public API has a gap. This use can identify that gap before third parties
  find it.
- No channel/socket dispatch erasure returns. The layer's heterogeneity is
  entirely closure-captured, and its typed server-side sends are checked
  against the live join's topic and generation before anything is unsealed,
  so that path has no erase/restore pair. This
  zero-coercion claim is scoped to channel/socket dispatch and type erasure;
  it does not include the validated raw-message coercion at the PubSub
  mailbox boundary described above and in ADR 0002.
- Tests enforce parity between the two APIs:
  the `phoenix_channel_fixtures` contract suite runs as a matrix over
  `beryl.child_spec` and `channel.child_spec`, since both lower to
  the same runtime, wire codec, presence, and abuse-control
  implementations. Each implementation exists only once.
- The union-and-router boilerplate ADR 0002 accepted (linear in channel
  count) does not apply to layer users. Raw-dispatch users are not affected.
  Third-party channels again use one handler value for distribution.
- Documentation presents one recommended default plus a short decision
  page (the channel layer for multi-channel, Phoenix-shaped apps; raw
  dispatch for single-topic apps and full control), rather than two
  co-equal tracks.
- No additional releasable package. Applications depend on `beryl` plus a
  transport and choose a programming model by importing `beryl/channel` or
  the raw `beryl/socket` types.
- ADR 0002's Status carries an "amended by ADR 0003" note; its Decision
  and Consequences are unchanged, because nothing this ADR ships alters
  the core.

## Revisions

The Decision above was proposed on 2026-08-02 and accepted the same day,
after the first implementation landed on an unreleased branch. Two bullets
described intentions that the implementation later improved. We rewrote both
bullets. The 2026-08-16 package-boundary amendment then moved the unchanged
public API into `beryl/channel`. The following list records the changes and
their reasons:

- **`join` receives `JoinContext`, not the core `ConnectInfo`.** The layer
  owns the socket-level model and message type, so handing a channel the
  core `ConnectInfo(msg)` would have exposed the layer's own envelope type
  to application code. `channel.JoinContext(info)` contains the data that a
  channel can use: connection data, the concrete topic, wildcard captures, the
  join payload, and this join's typed `Sender`. The soundness claim is
  unaffected: there is still no pre-join erased seed, because a channel's
  state is created inside `join` and sealed by `channel.accept`.
- **No erase/restore pair returns.** The proposal budgeted for one sound
  erase-at-send/restore-at-receive pair per handler registration. It was
  not needed. `channel.notify` seals the typed value in a closure that
  only its own join can open, and the router carries it inside an envelope
  stamped with that join's topic and a per-socket monotonic generation.
  Before it unseals any data, the router checks the stamp against the live
  instance. The router drops sealed mail for a superseded or ended join and
  cannot give it to a later join. The channel layer therefore
  contains no coercion for channel state or typed server-side messages. This
  does not remove or alter the validated PubSub raw-message coercion boundary.
