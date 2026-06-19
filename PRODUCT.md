# Product

## Register

brand

## Users

Gleam developers on the Erlang/BEAM target who are evaluating or learning beryl —
a type-safe real-time channels and presence library. They arrive from Hex, the
Gleam package index, GitHub, or word of mouth, usually to answer one of two
questions: "is this the right tool for my real-time feature?" and "how do I wire
up my first channel?" They are technical, skim-read, and judge a library's
maturity partly by the quality of its docs site. The surface is the Astro +
Starlight documentation/marketing site in `website/`.

## Product Purpose

The site is the public face of beryl. It must convert a curious developer into a
confident first-time user: communicate what beryl does (channels, presence,
PubSub, Phoenix-compatible wire protocol on the BEAM), prove it's credible and
modern, and get them to a working Quick Start fast. Success looks like a
developer landing on the splash page, immediately understanding the value, and
reaching a running channel without friction. It is pre-1.0 software, so the site
must be honest about stability while still feeling polished and alive.

## Brand Personality

Playful, bold, modern. Confident without being corporate. The voice is direct,
a little spirited, and unmistakably crafted by people who care — closer to a
sharp indie developer tool than an enterprise product. beryl is a green gemstone;
the brand leans into that vivid, faceted, mineral identity rather than hiding it.
Emotional goal: a developer should feel "these people have taste, this will be a
pleasure to use."

## Anti-references

- **Cold / corporate enterprise docs.** No sterile gray-on-white, no faceless
  enterprise tone, no committee-designed sameness. This is the explicit thing to
  avoid.
- Generic AI-generated SaaS landing pages (gradient blobs, hero-metric template,
  identical card grids).
- The bland default Starlight theme that looks like every other docs site.

## Design Principles

- **Show the gem.** Lean into beryl's green-mineral identity as a real point of
  view, not a default accent. The palette is voice.
- **Playful, but the code is the hero.** Personality lives in type, color, and
  motion; never at the expense of legible code samples and scannable docs.
- **Fast to first channel.** Every page should shorten the path from "what is
  this?" to "I have it running." Reduce friction, surface the Quick Start.
- **Honest about pre-1.0.** Communicate instability with confidence, not apology.
  Polish signals that the instability is a choice, not neglect.
- **Crafted, not corporate.** Every detail should read as deliberate and
  human-made — the opposite of cold enterprise docs.

## Accessibility & Inclusion

Target WCAG AA. Body text ≥4.5:1 contrast in both light and dark themes; verify
the green ramp doesn't wash out muted text. Respect `prefers-reduced-motion` for
every animation with a non-motion fallback. Keep the existing a11y-emoji and
link-validation tooling. Keyboard-navigable and screen-reader-friendly, as
inherited from Starlight, must be preserved through any customization.
