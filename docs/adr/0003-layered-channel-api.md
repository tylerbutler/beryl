# ADR 0003: Layered channel API on the dispatch core

## Status

Proposed (2026-08-02). Amends [ADR 0002](0002-app-side-dispatch.md): the
dispatch core and its soundness guarantees stand unchanged; this ADR
restores the channel-module ergonomics ADR 0002 traded away, as a separate
package layered on the public API. ADR 0001 anticipated this outcome — "a
layered variant (typed core with channels as sugar on top) may merit a
future ADR."

## Context

ADR 0002 replaced the channel-module API with app-side dispatch, gaining
full type safety and a single core API at the cost of the channel module as
the unit of composition: colocated callbacks, no hand-written union or
router, third-party channels usable without app-side wiring. That trade
was framed as either/or because both models competed to *be* the core.
They need not: the core's entry-point shape — `init:
fn(ConnectInfo(msg)) -> #(model, List(Effect))` and `update: fn(model,
Input(msg)) -> Next(model, msg)` (`beryl.child_spec`) — is expressive
enough to host a channel framework *above* the core, as ordinary data,
using the closure-captured existential encoding ADR 0001 already
validated ("Option B",
[#217](https://github.com/tylerbutler/beryl/pull/217)).

Interoperation between the two models is a non-goal: an application picks
raw dispatch or the channel layer per socket endpoint. (Nesting the layer
inside a larger `update` falls out of the design — the router is itself an
embeddable `model`/`msg`/`update` triple — but is not a supported
surface.)

## Decision

Ship a new package, `beryl_channels`, built strictly on beryl's public
API, with no access to internal modules:

- The entry point mirrors the supervised core:
  `beryl_channels.child_spec(config, handlers)`. It composes the handler
  list into an `#(init, update)` pair and delegates to
  `beryl.child_spec`. `Config` — including declarative per-topic abuse
  controls — is the core's, untouched. The layer does not reintroduce an
  unsupervised start path.
- A handler pairs a topic pattern with a typed `join` callback receiving
  the `ConnectInfo`, topic, and join payload, and returning either a
  rejection or a `JoinedChannel`: a record of closures (message, binary,
  info, terminate) that capture the channel's typed assigns, each
  returning the next `JoinedChannel` plus a list of channel actions. No
  erased assigns value ever exists — heterogeneity is encoded entirely in
  closures.
- The router's model is the handler table plus one live `JoinedChannel`
  per joined topic; its `update` matches each `Input` by topic to the
  owning instance. Channel actions map one-to-one onto core `Effect`
  values (the old API's single-action `HandleResult` shape generalizes to
  a list, a strict superset).
- The layer owns the socket-level `msg` type. Server-side sends to a
  specific channel erase the per-channel info type at the send site and
  restore it inside the joined closure — both ends created by the same
  handler registration, the sound pairing ADR 0001 documented for
  `send_info`. This is the only erasure in the layer, and it is
  quarantined there.
- ADR 0001's remaining unchecked coercion — connect-time assigns seeded
  erased and restored unchecked — closes structurally: `join` receives
  `ConnectInfo` directly, so there is no pre-join erased seed.

## Consequences

- `packages/beryl` is untouched. Every ADR 0002 claim — single core API,
  no erasure anywhere in core — remains literally true; ADR 0002's
  Consequences read unchanged, since restoration happens at a new layer,
  not by reverting the removal.
- The layer is the first dogfood of ADR 0002's composition story: the
  entire channel framework is an embeddable triple assembled from public
  API. Any capability it needs and cannot reach is a core public-API gap,
  surfaced before third parties hit it.
- One erase/restore pair returns, of the sound one-registration kind,
  confined to `beryl_channels`. Zero unchecked coercions anywhere in the
  workspace.
- Parity between the two APIs is enforced mechanically, not editorially:
  the `phoenix_channel_fixtures` contract suite runs as a matrix over
  `beryl.child_spec` and `beryl_channels.child_spec`, since both lower to
  the same runtime, wire codec, presence, and abuse-control
  implementations — which continue to exist exactly once.
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
- On acceptance, ADR 0002's Status gains an "amended by ADR 0003" note.
