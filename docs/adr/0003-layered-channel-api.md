# ADR 0003: Layered channel API on the dispatch core

## Status

Accepted (2026-08-02). Amends [ADR 0002](0002-app-side-dispatch.md): the
dispatch core and its soundness guarantees stand unchanged; this ADR
restores the channel-module ergonomics ADR 0002 traded away, as a separate
package layered on the public API. ADR 0001 anticipated this outcome — "a
layered variant (typed core with channels as sugar on top) may merit a
future ADR."

Shipped as `packages/beryl_channels`; its initial release is recorded in
that package's changelog. Two Decision bullets were rewritten on acceptance
to describe what shipped rather than what was proposed; see [Revisions on
acceptance](#revisions-on-acceptance).

## Context

ADR 0002 replaced the channel-module API with app-side dispatch, gaining
full type safety and a single core API at the cost of the channel module as
the unit of composition: colocated callbacks, no hand-written union or
router, third-party channels usable without app-side wiring. That trade
was framed as either/or because both models competed to *be* the core.
They need not: the core's entry-point shape — `init:
fn(ConnectInfo(msg)) -> #(model, List(Effect))` and `update: fn(model,
Input(msg)) -> Next(model, msg)` (`beryl.start`, `beryl.child_spec`) — is
expressive enough to host a channel framework *above* the core, as
ordinary data, using the closure-captured existential encoding ADR 0001
already validated ("Option B",
[#217](https://github.com/tylerbutler/beryl/pull/217)).

Interoperation between the two models is a non-goal: an application picks
raw dispatch or the channel layer per socket endpoint. (Nesting the layer
inside a larger `update` falls out of the design — the router is itself an
embeddable `model`/`msg`/`update` triple — but is not a supported
surface.)

## Decision

Ship a new package, `beryl_channels`, built strictly on beryl's public
API, with no access to internal modules:

- Entry points mirror the core: `beryl_channels.start(config, handlers)`
  and `beryl_channels.child_spec(config, handlers)`. Each composes the
  handler list into an `#(init, update)` pair and delegates to
  `beryl.start`/`beryl.child_spec`. `Config` — including declarative
  per-topic abuse controls — is the core's, untouched.
- A handler pairs a topic pattern with a typed `join` callback. The layer
  owns the socket-level model, so `join` receives a layer-built
  `channel.JoinInfo(info)` — the socket id, the transport's
  `socket.ConnectSeed`, and a `channel.Sender(info)` scoped to this join —
  rather than the core `ConnectInfo` itself, along with the concrete topic
  that matched and the client's join payload. It answers with a rejection
  or a `JoinedChannel`: a record of closures (message, binary, info,
  terminate) that capture the channel's typed state, each returning the
  next `JoinedChannel` plus a list of channel actions. No erased state
  value ever exists — heterogeneity is encoded entirely in closures.
- The router's model is the handler table plus one live `JoinedChannel`
  per joined topic; its `update` matches each `Input` by topic to the
  owning instance. Channel actions map one-to-one onto core `Effect`
  values (the old API's single-action `HandleResult` shape generalizes to
  a list, a strict superset) and lower in the order they were added.
  A join's accept-time actions (`channel.with_actions`) lower in the same
  update turn as the acknowledgment and strictly after it, so the socket
  is already subscribed and a push cannot overtake its own join reply.
  `on_terminate` returns topic-scoped actions that lower in the turn
  closing the topic, after the instance is removed: the topic is already
  unsubscribed there, so core drops pushes to it while broadcasts and
  presence track/untrack still reach the topic's remaining subscribers.
- The layer owns the socket-level `msg` type, and it carries no typed
  value: a socket message is an envelope stamped with a topic and a
  per-socket monotonic join generation, wrapping one sealed `Mail`.
  `channel.notify` seals the typed value in a closure that only the join
  which created it can open; the router compares the stamp against the
  live instance *before* anything is unsealed and drops mail for a
  superseded or ended join still sealed. Nothing is erased to `Dynamic`,
  so the sound one-registration erase/restore pair ADR 0001 documented for
  `send_info` is not needed at all.
- ADR 0001's remaining unchecked coercion — connect-time assigns seeded
  erased and restored unchecked — closes structurally: a channel's state
  is created inside `join` and sealed by `channel.joined`, so there is no
  pre-join erased seed to restore.

## Consequences

- `packages/beryl` is untouched. Every ADR 0002 claim — single core API,
  no erasure anywhere in core — remains literally true; ADR 0002's
  Consequences read unchanged, since restoration happens at a new layer,
  not by reverting the removal.
- The layer is the first dogfood of ADR 0002's composition story: the
  entire channel framework is an embeddable triple assembled from public
  API. Any capability it needs and cannot reach is a core public-API gap,
  surfaced before third parties hit it.
- No erasure returns. The layer's heterogeneity is entirely
  closure-captured, and its typed server-side sends are checked against
  the live join's topic and generation before anything is unsealed, so
  there is no erase/restore pair to confine. Zero unchecked coercions
  anywhere in the workspace.
- Parity between the two APIs is enforced mechanically, not editorially:
  the `phoenix_channel_fixtures` contract suite runs as a matrix over
  `beryl.start` and `beryl_channels.start`, since both lower to the same
  runtime, wire codec, presence, and abuse-control implementations —
  which continue to exist exactly once.
- The union-and-router boilerplate ADR 0002 accepted (linear in channel
  count) disappears for layer users; raw-dispatch users are unaffected.
  Third-party channels regain a wiring-free distribution shape: a handler
  value.
- Documentation presents one recommended default plus a short decision
  page (the channel layer for multi-channel, Phoenix-shaped apps; raw
  dispatch for single-topic apps and full control), rather than two
  co-equal tracks.
- One more releasable workspace package: trellis fan-out, its own
  changelog fragments and `beryl_channels-vX.Y.Z` tags, and a path
  dependency on `beryl` rewritten to a Hex requirement at publish, exactly
  as the transports do.
- ADR 0002's Status carries an "amended by ADR 0003" note; its Decision
  and Consequences are unchanged, because nothing this ADR ships alters
  the core.

## Revisions on acceptance

The Decision above was proposed on 2026-08-02 and accepted the same day,
after the package shipped. Two of its bullets described intentions that the
implementation improved on, and both were rewritten in place so the record
does not contradict `packages/beryl_channels`. What changed, and why:

- **`join` receives `JoinInfo`, not the core `ConnectInfo`.** The layer
  owns the socket-level model and message type, so handing a channel the
  core `ConnectInfo(msg)` would have exposed the layer's own envelope type
  to application code. `channel.JoinInfo(info)` carries what a channel can
  actually use — `socket_id`, the transport's `socket.ConnectSeed`, and
  this join's typed `Sender` — and nothing else. The soundness claim is
  unaffected: there is still no pre-join erased seed, because a channel's
  state is created inside `join` and sealed by `channel.joined`.
- **No erase/restore pair returns.** The proposal budgeted for one sound
  erase-at-send/restore-at-receive pair per handler registration. It was
  not needed. `channel.notify` seals the typed value in a closure that
  only its own join can open, and the router carries it inside an envelope
  stamped with that join's topic and a per-socket monotonic generation.
  The stamp is checked against the live instance *before* anything is
  unsealed, so mail for a superseded or ended join is dropped still
  sealed and can never be handed to a later join. The workspace therefore
  contains zero coercions of any kind, checked or unchecked.
