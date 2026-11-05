# Website components

## Overview

Astro components customize the beryl documentation site and illustrate tutorial
events with browser-local simulations.

## Interface

- [Head.astro](./Head.astro) wraps Starlight's default head, adds social image
  metadata through `ogImage`, and includes the Tinylytics `Script`.
- [Hero.astro](./Hero.astro) reads `Astro.locals.starlightRoute.entry.data.hero`
  for its title, tagline, image, and actions. `isHome` selects the gem and code
  presentation when `gem` is present.
- [InstallDependencies.astro](./InstallDependencies.astro) renders the
  `dependencies` TOML snippet for `beryl` and `beryl_mist` using a release `ref`.
- [SharedPollDemo.astro](./SharedPollDemo.astro), [SocketLoopDemo.astro](./SocketLoopDemo.astro),
  and [TopicCompositionDemo.astro](./TopicCompositionDemo.astro) register
  `shared-poll-demo`, `socket-loop-demo`, and `topic-composition-demo`.
  Their controls simulate voting, socket updates/replies, and topic composition.
- [tutorial-demo.ts](./tutorial-demo.ts) exports `element`, `animate`, and
  `cancelMotion` for typed DOM lookup and animation delivery/cleanup.

## Invariants

- `element` throws when the required element is missing or has the wrong type.
  `animate` delivers its callback without animation when the browser requests
  reduced motion. (`tutorial-demo.ts:element`, `tutorial-demo.ts:animate`)
- The poll's vote handler requires a joined room and a supported choice. It
  permits repeated votes and has no closing timer.
  (`SharedPollDemo.astro:SharedPollDemo`)
- A counter increment changes the model without emitting effects; a request
  captures the count for its reply when creating the effect.
  (`SocketLoopDemo.astro:SocketLoopDemo`)
- Switching the topic demo's explanatory view preserves scenario state.
  Leaving and rejoining the poll resets its displayed totals.
  (`TopicCompositionDemo.astro:TopicCompositionDemo`)

## Side effects

- Rendering `InstallDependencies` runs `git ls-remote` against the GitHub
  repository with a 30-second timeout. The component throws if it cannot find
  a matching minor-release tag. (`InstallDependencies.astro:ref`)
- `Head` includes the configured Tinylytics script.
  (`Head.astro:Script`)
- Demo custom elements attach event listeners, mutate DOM state, and animate
  messages. Their disconnect handlers cancel motion. These demos simulate
  server behavior in the browser; they do not open server connections.
  (`SharedPollDemo.astro:connectedCallback`,
  `SocketLoopDemo.astro:disconnectedCallback`,
  `TopicCompositionDemo.astro:connectedCallback`, `tutorial-demo.ts:cancelMotion`)
- The hero uses CSS entrance and floating animations, with reduced-motion
  overrides. (`Hero.astro:prefers-reduced-motion`)

## Verification

From `website/`, use `pnpm check:astro` for Astro/TypeScript checks,
`pnpm test:demos` for the Playwright demo suite, and `pnpm build:site` for the
site build. These commands come from [package.json](../../package.json).
The build can trigger the release-tag lookup above.
