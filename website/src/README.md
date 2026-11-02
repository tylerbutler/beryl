# Website source

## Overview

This directory configures Starlight's documentation collection and contains
the site's Astro components.

## Subdirectories and boundaries

- [Components](./components/README.md) customize the head/hero and implement
  browser-local tutorial demos. Their contract covers render-time release
  lookup and browser animation behavior.

## Interface

- [content.config.ts](./content.config.ts) exports `collections.docs` through
  Astro's `defineCollection`, with Starlight's `docsLoader()` and `docsSchema()`.
- [env.d.ts](./env.d.ts) references Astro's generated type declarations.

## Invariants

- The `docs` collection uses the Starlight loader and schema.
  (`content.config.ts:collections.docs`)
- `env.d.ts` points to `../.astro/types.d.ts`; it declares no additional local
  types. (`env.d.ts:reference`)

## Side effects

The local collection/type declarations contain no explicit I/O. Child
components include a render-time GitHub tag lookup, analytics script inclusion,
and browser DOM/animation changes; see the [component contract](./components/README.md).
(`content.config.ts:collections.docs`, `env.d.ts:reference`,
`components/InstallDependencies.astro:ref`, `components/Head.astro:Script`,
`components/tutorial-demo.ts:animate`)

## Verification

From `website/`, use `pnpm check:astro` and `pnpm build:site` to check the
collection and component integration. `pnpm test:demos` runs the browser demo
suite. [package.json](../package.json) defines these commands.
