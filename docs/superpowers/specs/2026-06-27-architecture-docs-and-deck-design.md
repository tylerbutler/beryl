# Architecture Documentation & MARP Deck — Design

Date: 2026-06-27
Status: Approved (pending spec review)

## Goal

Produce onboarding-focused architecture documentation that explains how beryl
works — its layers, the main modules, what each does, and how they fit
together — so a new contributor or maintainer can orient quickly and know where
to make changes. Deliver this as (1) a multi-page Architecture section on the
docs website and (2) a self-contained MARP slide deck that renders to HTML.

## Audience

Primary: new contributors / maintainers onboarding to the codebase. Emphasis on
module responsibilities, message flows, OTP supervision, concurrency gotchas,
and "where does this live / where do I change it" — not a marketing pitch.

## Non-goals

- No user-facing tutorial content (the Guides section already covers usage).
- No PDF export of the deck (HTML only).
- No refactoring of `src/` code. Docs only, plus minimal build wiring.

## Deliverables

### 1. Architecture section (`website/src/content/docs/architecture/`)

All diagrams use Mermaid. Every page ends with a short "Where this lives in
`src/`" pointer listing the relevant modules.

1. **`overview.md`** (revise existing 142-line page)
   - Keep the layer diagram (convert to Mermaid) and a one-paragraph-per-module
     map.
   - Trim deep per-module prose that now lives on subsystem pages.
   - Add a contributor orientation: how to read these docs, a `src/beryl/*`
     file map, and the OTP process/supervision picture at a glance.

2. **`message-lifecycle.md`** (new — centerpiece)
   - End-to-end flows with Mermaid sequence diagrams:
     - connect → socket registration with the coordinator
     - join topic → handler dispatch → reply
     - `handle_in` user event → reply
     - broadcast → pubsub fan-out → client receive
     - heartbeat enforcement / eviction
     - disconnect → `terminate` cleanup
   - Where this lives: `transport/mist`, `coordinator`, `wire`, `pubsub`.

3. **`coordinator.md`** (new)
   - Central OTP actor: handler registry, type erasure for heterogeneous
     `assigns`, socket tracking, topic→subscriber maps, message routing,
     heartbeat timer.
   - Supervision tree: rest-for-one order coordinator → presence → groups, and
     crash/restart semantics; `child_spec` embedding.
   - Where this lives: `coordinator`, `supervisor`.

4. **`pubsub-and-distribution.md`** (new)
   - `pg`-based process groups, the Erlang FFI (`beryl_pubsub_ffi.erl`),
     cross-node broadcast, and `broadcast_from` exclusion semantics.
   - Where this lives: `pubsub`, `beryl_pubsub_ffi.erl`.

5. **`presence.md`** (new)
   - CRDT actor wrapping `lattice_presence` (add-wins observed-remove),
     track/untrack, periodic replication via pubsub, `on_diff` callbacks,
     `State`/`Diff` aliases.
   - Where this lives: `presence`, `presence/wire`.

6. **`wire-and-transport.md`** (new)
   - Codec abstraction and the Phoenix codec frame shapes
     (`[join_ref, ref, topic, event, payload]`, replies, pushes, heartbeats);
     Mist transport responsibilities; text vs binary handling.
   - Where this lives: `wire`, `wire/codec`, `transport/mist`.

Cross-cutting modules (`group`, `topic`, `socket`, `error`, `rate_limit`,
`bridge`, `log`, `internal`) remain summarized in `overview.md` and covered by
the Guides; they do not get dedicated architecture pages.

BEAM mailbox / concurrency gotchas (selective receive, draining queued
messages) are folded into `message-lifecycle.md` and `coordinator.md` where
relevant.

### 2. MARP deck (`docs/architecture-deck.md`)

- ~15–20 slides, condensed narrative derived from the same material:
  what beryl is + the layer stack; the one big diagram; each subsystem in 1–2
  slides (coordinator, pubsub, presence, wire/transport, supervision); the
  message lifecycle as a few build-up slides; a "where to start contributing"
  closer.
- Mermaid diagrams throughout.
- Renders to **HTML only**.

### 3. Build wiring

- **Website:** add `astro-mermaid` (client-side Mermaid rendering) to
  `website/package.json` and configure it in `website/astro.config.mjs`.
  Add the 5 new pages to the Starlight sidebar Architecture group.
- **Deck:** add `docs/marp.engine.mjs` — a custom marp engine that maps
  ```` ```mermaid ```` fences to `<div class="mermaid">…</div>` and injects the
  Mermaid script + `mermaid.initialize` so the rendered HTML draws diagrams
  client-side in the browser.
- **justfile:** add a `deck` recipe:
  `npx -y @marp-team/marp-cli docs/architecture-deck.md --engine docs/marp.engine.mjs --html -o docs/architecture-deck.html`
  (exact flags finalized during implementation; `--html` allows the injected
  Mermaid markup).

## Approach notes / trade-offs

- **Client-side Mermaid (both surfaces)** avoids a headless-browser build
  dependency (no Playwright/Puppeteer at build time). Cost: diagrams render in
  the viewer's browser rather than being baked into static SVG. Acceptable for
  internal docs and an HTML deck.
- **Accuracy:** each `src/beryl/*` module is deep-read before its page/slides
  are written, so flows and diagrams reflect the real code rather than the
  existing overview prose.

## Verification

- `website`: `pnpm install` (Node 22+, pnpm 10) then the site build succeeds and
  Mermaid diagrams render on the new pages; `starlight-links-validator` passes.
- `deck`: `just deck` produces `docs/architecture-deck.html`; opening it shows
  slides with rendered Mermaid diagrams.
- `just format-check` / repo CI conventions respected for any touched files.
- A changie fragment is added (user-visible docs + new tooling recipe).

## Risks

- `astro-mermaid` compatibility with Astro 6 / Starlight 0.39 — verify during
  implementation; fall back to an alternative Mermaid integration if needed.
- marp custom-engine Mermaid injection — verify the HTML output actually renders
  diagrams; adjust the engine/script injection if not.
