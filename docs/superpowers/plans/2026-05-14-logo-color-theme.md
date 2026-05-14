# Logo Color Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retheme the website so Starlight colors are primarily forest green, matching the beryl logo, with pink used only as a restrained accent.

**Architecture:** This is a token-only CSS change. `website/src/styles/custom.css` defines Starlight custom properties for dark and light themes; updating those variables propagates through the existing Starlight layout without touching content, routing, images, or Astro configuration.

**Tech Stack:** Astro 6, Starlight, CSS custom properties, existing npm scripts in `website/package.json`.

---

## File structure

- Modify `website/src/styles/custom.css`: replace the current pink-forward Starlight color tokens with logo-derived green palettes for dark and light mode.
- No new source files, tests, routes, assets, or config files are required.
- Do not modify `website/astro.config.mjs`; it already points at `website/src/assets/beryl.webp` for the logo and `website/src/assets/beryl.png` for the favicon.

### Task 1: Update Starlight theme tokens

**Files:**
- Modify: `website/src/styles/custom.css:1-29`

- [ ] **Step 1: Confirm the current CSS is pink-forward**

Run:

```bash
sed -n '1,80p' website/src/styles/custom.css
```

Expected: output shows `--sl-color-accent` and most gray tokens using pink/magenta values such as `#ab3772`, `#ff729e`, and `#340014`.

- [ ] **Step 2: Replace the full file with the green-forward logo palette**

Edit `website/src/styles/custom.css` so the complete file is:

```css
/* Dark mode colors. */
:root {
	--sl-color-accent-low: #14351d;
	--sl-color-accent: #b21f5c;
	--sl-color-accent-high: #ffd4e5;
	--sl-color-white: #f2ffe9;
	--sl-color-gray-1: #d8f7c5;
	--sl-color-gray-2: #a9df89;
	--sl-color-gray-3: #75b85b;
	--sl-color-gray-4: #39733f;
	--sl-color-gray-5: #27522f;
	--sl-color-gray-6: #183821;
	--sl-color-black: #07150c;
}
/* Light mode colors. */
:root[data-theme='light'] {
	--sl-color-accent-low: #d8f0c9;
	--sl-color-accent: #276f35;
	--sl-color-accent-high: #123f21;
	--sl-color-white: #07150c;
	--sl-color-gray-1: #123f21;
	--sl-color-gray-2: #27522f;
	--sl-color-gray-3: #39733f;
	--sl-color-gray-4: #6aa44d;
	--sl-color-gray-5: #a9df89;
	--sl-color-gray-6: #e6f7dc;
	--sl-color-gray-7: #f7fff2;
	--sl-color-black: #ffffff;
}
```

This palette maps the logo's deep forest facets to surfaces and text, the bright green facets to gray ramps/highlights, and the pink shard to the dark-mode accent only. Light mode keeps the primary accent green to satisfy the "mostly green" requirement.

- [ ] **Step 3: Review the diff**

Run:

```bash
git --no-pager diff -- website/src/styles/custom.css
```

Expected: only `website/src/styles/custom.css` has source changes, and every changed color token moves from pink/magenta values to green values except the restrained dark-mode `--sl-color-accent`.

- [ ] **Step 4: Commit the theme token change**

Run:

```bash
git add website/src/styles/custom.css
git commit -m "style(website): align theme with logo colors"
```

Expected: git creates a commit containing only `website/src/styles/custom.css`.

### Task 2: Validate the website

**Files:**
- Validate: `website/src/styles/custom.css`
- Read if failures occur: `website/package.json`

- [ ] **Step 1: Run Astro check**

Run:

```bash
cd website && npm run check:astro
```

Expected: command exits successfully with Astro reporting no type or content errors.

- [ ] **Step 2: Run site build**

Run:

```bash
cd website && npm run build:site
```

Expected: command exits successfully and builds the site into `website/dist`.

- [ ] **Step 3: Check git status for generated artifacts**

Run:

```bash
git --no-pager status --short
```

Expected: no generated `website/dist` files are staged. If `website/dist` appears as untracked output, leave it untracked and do not commit it.

- [ ] **Step 4: Commit validation-related changes only if any tracked files changed**

Run:

```bash
git --no-pager diff --stat
```

Expected: no tracked files changed during validation. Do not create a commit if the diff is empty.

## Self-review

- Spec coverage: the plan updates only `website/src/styles/custom.css`, preserves logo/config/content, uses a green-forward palette with restrained pink, and runs the requested Astro check/build.
- Placeholder scan: no placeholder tasks or unspecified implementation steps remain.
- Type consistency: no TypeScript, Gleam, or runtime API changes are introduced; CSS token names match the current Starlight variables already used in the file.
