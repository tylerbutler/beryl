# beryl website

## Overview

The beryl documentation website uses Astro and Starlight. This package has its
own Node.js dependencies and commands in [package.json](./package.json).
Use Node.js 22.12.0 or newer and the declared pnpm version, 12.16.1.

## Subdirectories and boundaries

- [Source](./src/README.md) configures the documentation collection and groups
  the custom Astro components.
- [Scripts](./scripts/README.md) check Gleam documentation snippets and generate
  reference pages and the social image. Generated reference pages are outputs,
  not handwritten contracts.

## Interface

- [astro.config.mjs](./astro.config.mjs) exports `defineConfig` for
  `https://beryl.tylerbutler.com`, with Mermaid and Starlight integrations,
  custom `Head`/`Hero` components, and sidebar navigation. Its `redirects` entry
  maps `/reference/api/beryl-stats/` to `/reference/api/beryl-snapshot/`.
- [package.json](./package.json) exposes `dev`, `build:site`, `preview`,
  `check:astro`, `check:snippets`, `test:demos`, `test:reference`, and generation
  commands. `deploy` builds the site before running `wrangler deploy`.
- [netlify.toml](./netlify.toml) sets `pnpm build:site` and publishes `dist`.
  [wrangler.toml](./wrangler.toml) configures static assets from `./dist` with
  `404-page` handling.

## Invariants

- The link validator's `failOnError` is `Boolean(process.env.CI)`.
  (`astro.config.mjs:starlightLinksValidator`)
- TypeScript extends `astro/tsconfigs/strictest`.
  (`tsconfig.json:extends`)
- `build:site` runs `astro build`; it does not run reference or social-image
  generation. Regenerate those outputs through their separate commands.
  (`package.json:scripts.build:site`, `package.json:scripts.generate:reference`,
  `package.json:scripts.generate:og`)
- The reference generator replaces its output directory. Preserve handwritten
  content outside that output and change API documentation at its source.
  (`scripts/generate-reference.mjs:generateReference`,
  `scripts/generate-reference.mjs:GENERATED_MARKER`)

## Side effects

- Astro builds write site output. The dependency snippet component can run a
  networked `git ls-remote` lookup while rendering.
  (`package.json:scripts.build:site`, `src/components/InstallDependencies.astro:ref`)
- Child scripts write generated references, an image, or snippet-check work
  files and invoke external tools. See their [contract](./scripts/README.md)
  before running them. (`scripts/generate-reference.mjs:generateReference`,
  `scripts/generate-og-image.mjs:output`, `scripts/check-snippets.mjs:main`)
- The site's head includes Tinylytics; tutorial demos mutate browser-local DOM
  state and animations. (`src/components/Head.astro:Script`,
  `src/components/tutorial-demo.ts:animate`)
- `deploy` publishes through Wrangler. `clean` removes `dist`, Astro state,
  TypeScript build metadata, and build logs.
  (`package.json:scripts.deploy`, `package.json:scripts.clean`)

## Verification

Run commands from `website/`:

- `pnpm check:astro` checks Astro and TypeScript.
- `pnpm build:site` builds the site and applies the configured link validation.
- `pnpm test:reference` runs the Node.js reference generator tests.
- `pnpm test:demos` runs the Playwright demo suite.
- `pnpm check:snippets` checks Gleam documentation snippets; see the
  [script prerequisites and write effects](./scripts/README.md).
