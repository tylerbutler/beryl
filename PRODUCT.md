# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The primary users are Gleam developers on the Erlang/BEAM target who are
evaluating or learning Beryl. They arrive from Hex, the Gleam package index,
GitHub, or word of mouth to decide whether Beryl fits a realtime feature and
to learn how to build their first channel. They are technical, skim-read, and
use documentation quality as evidence of library maturity.

## Product Purpose

Beryl provides type-safe realtime channels, presence, and PubSub for Gleam on
the BEAM. It gives developers a direct path from a typed application model to
Phoenix-compatible WebSocket behavior without requiring an Elixir or Phoenix
application.

The website is Beryl's public product surface. It must help a curious developer
understand the library, choose an API, and reach a working first channel with
little friction. Success means that developers can evaluate Beryl accurately,
run an example, and apply the documented model in their own supervised Gleam
application.

## Positioning

Beryl combines typed app-dispatch and channel APIs with Phoenix-compatible wire
behavior on Gleam and the Erlang/BEAM runtime. The type-safe application model,
public transport SPI, and Phoenix protocol compatibility are one system rather
than separate integrations.

## Operating Context

Developers evaluate Beryl through the Astro and Starlight website in `website/`,
the generated API reference, GitHub source, and runnable examples. They add a
Beryl package to a Gleam application, choose raw app dispatch or
`beryl/channel`, select a wire codec and WebSocket transport, place Beryl's
child specification in an OTP supervision tree, and connect a compatible
client.

The repository is a trellis-managed monorepo. Core behavior lives in
`packages/beryl/`; Mist and Ewe transports live in separate packages and use
the public `beryl/transport` SPI. Examples under `examples/` demonstrate
complete application flows.

## Capabilities and Constraints

- Beryl supports typed socket events and effects, channels, presence, PubSub,
  groups, runtime statistics, wire codecs, and pluggable WebSocket transports.
- The built-in codec implements the Phoenix wire format.
- Beryl targets Erlang/BEAM. Transport packages must depend only on the public
  transport SPI and must not import Beryl's internal runtime modules.
- Configuration APIs are opaque and use builder functions.
- Fallible public APIs return `Result`; public behavior must preserve exhaustive
  matching and typed boundaries.
- Beryl is pre-1.0. The website must describe evolving APIs accurately and must
  not imply stability guarantees that do not exist.
- The website uses Astro and Starlight and must preserve link validation,
  generated reference content, keyboard navigation, and screen-reader support.

## Brand Commitments

The product name is **beryl**, represented by the green gemstone asset at
`website/src/assets/beryl.webp`. The voice is direct, confident, playful, and
crafted rather than corporate. Code and technical clarity remain primary.

The brand must not become cold enterprise documentation, a generic SaaS
template, or an unmodified Starlight theme. Personality must not reduce code
legibility, documentation scanability, or trust.

## Evidence on Hand

- Runnable applications under `examples/`, including the live-poll tutorial
  checkpoints in `examples/blog_series/`.
- Generated API documentation under
  `website/src/content/docs/reference/api/`.
- Integration and contract tests under each package's `test/` directory,
  including runtime, Phoenix wire, transport, presence, and PubSub behavior.
- Architecture decisions and technical documentation under `docs/`.

Future work must use these sources as evidence and must not fabricate customers,
testimonials, adoption metrics, benchmarks, or stability claims.

## Product Principles

- **Typed boundaries first.** Preserve type safety from application messages
  through socket and channel behavior.
- **Fast to a working channel.** Shorten the path from evaluation to a running,
  supervised example.
- **Show complete runtime behavior.** Explain transport, wire, actor,
  supervision, and reconnection boundaries instead of presenting only callback
  snippets.
- **Use executable proof.** Keep examples, generated reference material, and
  integration tests aligned with product claims.
- **Be candid about pre-1.0 change.** Describe current behavior precisely
  without overstating stability.

## Accessibility & Inclusion

Target WCAG AA. Body text must reach 4.5:1 contrast in light and dark themes.
Respect `prefers-reduced-motion` and provide a non-motion fallback. Preserve
keyboard navigation, screen-reader support, the a11y-emoji plugin, and link
validation through website changes.
