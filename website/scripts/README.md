# Website scripts

## Overview

These Node.js entry points check documentation snippets and generate API
reference pages or the social image. [package.json](../package.json) defines
their commands and dependencies.

## Interface

- [check-snippets.mjs](./check-snippets.mjs) runs `main` as a CLI.
  `--deps-only` stops after project/dependency setup; `--keep` retains generated
  snippet sources. `collectSources` gathers Gleam fences from Markdown/MDX
  and package `///` documentation comments. It also requires the complete
  Quick start examples in the root README and core module's `////` comments.
- [generate-reference.mjs](./generate-reference.mjs) exports
  `generateReference({ docsJsonPath, docsJsonPaths, outputDir, workspacePackages,
  workspaceRoot })`, returning `{ pageCount, moduleCount }`. `docsJsonPaths`
  takes precedence over `docsJsonPath`; otherwise `discoverPackageInterfaces`
  discovers workspace package interfaces. Direct CLI invocation uses defaults.
- [generate-og-image.mjs](./generate-og-image.mjs) executes on load. Its `svg`
  combines fixed copy, code, and artwork with three font files from installed
  dependencies; `sharp` renders the image.

## Invariants

- `SKIPPED_DOC_DIRS` excludes `api` from snippet discovery. A
  `snippet-check: skip` marker before a documentation fence excludes that
  block. (`check-snippets.mjs:SKIPPED_DOC_DIRS`,
  `check-snippets.mjs:fencedGleamBlocks`)
- Snippet checking assembles fragments into modules and fills missing context
  with placeholders/import inference. It is not a runtime check of tutorial
  behavior. Placeholder resolution has a 12-round limit.
  (`check-snippets.mjs:assembleModule`, `check-snippets.mjs:MAX_PLACEHOLDER_ROUNDS`)
- The two complete quick starts compile verbatim in separate modules, without
  inferred imports, placeholders, or suppressed compiler errors. A missing or
  duplicate Quick start section or Gleam block fails the check. Diagnostics map
  back to the published source lines. (`check-snippets.mjs:quickStartSource`,
  `check-snippets.mjs:assembleModule`, `check-snippets.mjs:checkSources`)
- `readPackageInterface` checks the interface's name and modules fields;
  `generateReference` rejects module page collisions. Keep generated reference
  pages disposable: the default output is `src/content/docs/reference/api`,
  and generation replaces that directory. Edit source documentation rather
  than generated Markdown. (`generate-reference.mjs:readPackageInterface`,
  `generate-reference.mjs:generateReference`, `generate-reference.mjs:GENERATED_MARKER`)
- The social card uses `size` of 1200 by 630 pixels and `output` of
  `public/og.png`. `build:site` does not invoke its generator.
  (`generate-og-image.mjs:size`, `generate-og-image.mjs:output`,
  `../package.json:scripts.build:site`)

## Side effects

- Snippet checking writes its project and generated modules under
  `build/snippet-check` at the repository root, calls the imported
  `prepareDependencies` helper, and runs `gleam build`. Normal completion
  removes generated `src` unless `--keep` applies; early errors may leave it.
  Unsuppressed findings set exit code 1.
  (`check-snippets.mjs:workDir`, `check-snippets.mjs:main`,
  `check-snippets.mjs:build`)
- Default reference discovery executes `trellis --no-update-check list --json`.
  Generation reads package-interface JSON and deletes/recreates the selected
  `outputDir`, including caller-supplied paths, before writing the index and
  module pages. The handwritten reference index outside the default output
  directory remains untouched.
  (`generate-reference.mjs:listWorkspacePackages`,
  `generate-reference.mjs:generateReference`)
- Social image generation reads installed WOFF2 fonts, creates the output
  directory, overwrites `public/og.png`, and logs its path.
  (`generate-og-image.mjs:asDataUrl`, `generate-og-image.mjs:output`)

## Verification

From `website/`, `pnpm test:reference` runs the reference generator tests.
`pnpm test:snippets` prepares the existing snippet project and runs extraction
tests plus compiler-backed drift regressions against the published quick starts.
`pnpm check:snippets` runs the snippet checker and requires Gleam, package
dependencies, and package-interface metadata.
From the repository root, `just site-snippets` builds metadata, runs the snippet
tests, and checks the full documentation corpus.
Use `pnpm generate:reference` or `pnpm generate:og` to regenerate their outputs,
not as read-only checks. [package.json](../package.json) defines these commands.
