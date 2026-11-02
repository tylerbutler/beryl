# Design documentation

## Overview

This directory holds design proposals and an architecture slide deck.
Treat proposals as design context, not proof of implemented behavior.
The local executable component is the [Marp engine hook](./marp.engine.mjs).

## Interface

- The default export accepts `{ marp }`, replaces its Markdown fence
  renderer, and returns that engine. [marp.engine.mjs:default]
- The hook emits `<pre class="mermaid">` for fences whose trimmed info
  string equals `mermaid`; other fences use the original renderer.
  [marp.engine.mjs:default]
- [Architecture deck](./architecture-deck.md) and
  [supervision diagram](./beryl-supervision-trees.svg) provide visual context.
- Design notes cover [portable channel core](./portable-channel-core-spec.md),
  its [implementation plan](./portable-channel-core-plan.md),
  [Lustre integration](./lustre-integration-plan.md),
  [typed PubSub actors](./pubsub-typed-actor-plan.md), and
  [FFI reduction](./gleam-ffi-reduction-plan.md).

## Invariants

The caller must supply a Marp engine with
`markdown.renderer.rules.fence`. Preserve the original fence renderer for
non-Mermaid input. [marp.engine.mjs:default]

## Side effects

The hook mutates the supplied engine's fence-rendering rule. It performs no
file, network, or subprocess operations itself. [marp.engine.mjs:default]
The separate `just deck` recipe invokes `npx` and Marp, may download tooling,
and writes `docs/architecture-deck.html`. [justfile:deck]

## Verification

From the repository root, `node --check docs/marp.engine.mjs` checks hook
syntax without rendering or downloading tools. `just deck` renders the deck
with this engine when you intend to generate HTML; it is not an offline
syntax check. [justfile:deck]
