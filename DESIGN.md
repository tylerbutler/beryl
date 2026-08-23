---
name: beryl
description: A faceted, code-first documentation system for realtime Gleam development.
colors:
  page-dark: "oklch(0.165 0.022 162)"
  surface-dark: "oklch(0.215 0.028 163 / 0.7)"
  hairline-dark: "oklch(0.42 0.04 161 / 0.5)"
  text-bright: "oklch(0.97 0.018 152)"
  text-muted: "oklch(0.81 0.032 157)"
  emerald-low: "oklch(0.31 0.07 160)"
  emerald: "oklch(0.78 0.16 158)"
  emerald-high: "oklch(0.9 0.1 154)"
  morganite: "oklch(0.72 0.2 350)"
  page-light: "oklch(0.985 0.01 150)"
  surface-light: "oklch(1 0 0 / 0.6)"
  hairline-light: "oklch(0.55 0.04 158 / 0.35)"
  text-light: "oklch(0.2 0.05 163)"
  text-muted-light: "oklch(0.38 0.05 161)"
  emerald-light: "oklch(0.5 0.15 156)"
  morganite-light: "oklch(0.52 0.23 352)"
typography:
  display:
    fontFamily: "Unbounded Variable, Hanken Grotesk Variable, system-ui, sans-serif"
    fontSize: "clamp(3rem, 8vw, 5.25rem)"
    fontWeight: 700
    lineHeight: 0.92
    letterSpacing: "-0.03em"
  headline:
    fontFamily: "Unbounded Variable, Hanken Grotesk Variable, system-ui, sans-serif"
    fontSize: "clamp(2.1rem, 1.4rem + 2.6vw, 3.1rem)"
    fontWeight: 700
    lineHeight: 1.04
    letterSpacing: "-0.03em"
  body:
    fontFamily: "Hanken Grotesk Variable, system-ui, -apple-system, Segoe UI, sans-serif"
  mono:
    fontFamily: "JetBrains Mono Variable, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.875em"
  label:
    fontFamily: "Hanken Grotesk Variable, system-ui, sans-serif"
    fontSize: "0.62rem"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.02em"
rounded:
  inline: "5px"
  icon: "10px"
  code: "12px"
  card: "14px"
  feature: "16px"
  pill: "999px"
spacing:
  xs: "0.4rem"
  sm: "0.75rem"
  md: "1rem"
  lg: "1.5rem"
  xl: "2.75rem"
components:
  button-primary:
    backgroundColor: "{colors.emerald}"
    textColor: "{colors.page-dark}"
    typography: "{typography.body}"
    rounded: "{rounded.pill}"
    padding: "0.9375rem 1.25rem"
    height: "44px"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.text-bright}"
    typography: "{typography.body}"
    rounded: "{rounded.pill}"
    padding: "0.9375rem 1.25rem"
    height: "44px"
  card:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.text-bright}"
    rounded: "{rounded.card}"
  aside-note:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.text-bright}"
    rounded: "{rounded.card}"
    padding: "1rem 1.25rem"
  inline-code:
    backgroundColor: "oklch(0.72 0.2 350 / 0.16)"
    textColor: "{colors.text-bright}"
    typography: "{typography.mono}"
    rounded: "{rounded.inline}"
    padding: "0.15em 0.4em"
---

# Design System: beryl

## Overview

**Creative North Star: "The Emerald Workbench"**

The system treats documentation as a carefully equipped technical workbench
cut from a green gemstone. Near-black green surfaces, warm off-white light
surfaces, emerald actions, and a small morganite accent make the product feel
crafted without competing with code. The visual voice is tactile, precise, and
quietly playful.

The interface stays familiar enough for sustained reading. Expressive moments
are concentrated in the faceted hero, display headings, status details, and
interaction states. Long-form documentation remains calm, legible, and
structurally conventional.

**Key Characteristics:**

- Gemstone greens form the environment; morganite marks small moments of
  emphasis.
- Unbounded gives the brand and page titles a wide, unmistakable silhouette.
- Hanken Grotesk carries long-form reading and interface labels.
- JetBrains Mono keeps code compact and developer-native.
- Tonal layers define surfaces at rest; glow and lift appear during interaction.
- Faceted geometry appears as a signature detail, not as repeated decoration.

## Colors

The default dark theme uses deep mineral greens with luminous emerald and
morganite accents. The light theme preserves the same hue relationships with
darker accents and green-tinted off-white surfaces.

### Primary

- **Workbench Emerald** (`emerald`): links, primary actions, selected states,
  focus rings, and interactive borders.
- **Deep Emerald Bed** (`emerald-low`): quiet accent backgrounds and icon
  surfaces in the dark theme.
- **Crystal Emerald** (`emerald-high`): high-emphasis accent text on dark
  surfaces.

### Secondary

- **Morganite Spark** (`morganite`): the wordmark period, section markers,
  status details, selection tint, and small signature accents.

### Neutral

- **Mineral Night** (`page-dark`): the default dark page ground.
- **Cut-Stone Surface** (`surface-dark`): translucent cards, code frames, and
  contained modules.
- **Crystal Text** (`text-bright`): headings and strongest dark-theme text.
- **Mist Text** (`text-muted`): secondary dark-theme prose.
- **Green-Tinted Paper** (`page-light`): the light page ground.
- **Ink Green** (`text-light`): headings and strongest light-theme text.
- **Mineral Hairlines** (`hairline-dark`, `hairline-light`): borders and
  dividers that stay subordinate to content.

**The Two-Stone Rule.** Emerald carries interaction and structure; morganite
marks rare emphasis. Do not introduce an unrelated accent hue.

**The Theme-Pair Rule.** Light mode uses purpose-built darker accents and
shadows. It is not the dark palette with opacity reduced.

## Typography

**Display Font:** Unbounded Variable with Hanken Grotesk and system sans
fallbacks  
**Body Font:** Hanken Grotesk Variable with system sans fallbacks  
**Label/Mono Font:** JetBrains Mono Variable for code; Hanken Grotesk for labels

**Character:** Unbounded makes product identity broad, faceted, and playful.
Hanken Grotesk keeps dense technical prose warm and readable. JetBrains Mono
signals code through function rather than decoration.

### Hierarchy

- **Display** (700, fluid 3rem to 5.25rem, 0.92 line height): the homepage
  wordmark and no other recurring prose.
- **Headline** (700, fluid 2.1rem to 3.1rem, 1.04 line height): top-level page
  titles.
- **Title** (700, compact tracking): section headings and feature titles,
  usually in Hanken Grotesk for long-form readability.
- **Body** (regular, readable measure): documentation prose, lists, navigation,
  and component copy. Keep long-form measure near 60-75 characters.
- **Label** (700, compact): status badges and short interface metadata.
- **Mono** (0.875em where inline): code, commands, API names, and technical
  values only.

**The Wide-Type Rule.** Unbounded belongs to the wordmark, page titles, and
short display moments. Do not use it for paragraphs or dense navigation.

**The Code-Is-Code Rule.** JetBrains Mono marks executable or literal content;
it is never a decorative substitute for interface typography.

## Layout

Documentation follows Starlight's stable header, sidebar, content column, and
table-of-contents model. Reading pages prioritize scanability and a restrained
65-75 character prose measure. Vertical rhythm increases before sections:
content H2 headings use a 2.75rem top margin and a short morganite marker.

The homepage begins as one centered column. At 68rem it becomes an asymmetric
5:6 split between the value statement and the code-and-gem stage. Feature
content becomes a six-column ledger at 50rem; the lead feature spans all six
columns and the remaining features span two each. Cards and ordered paths use
fluid padding rather than adding breakpoint-specific variants.

**The Code-First Layout Rule.** Code samples can become the dominant visual
object, but surrounding prose must retain a readable measure and an obvious
route to the next action.

## Elevation & Depth

The system is layered: tonal surfaces and hairline borders define objects at
rest, while mineral glow and small vertical movement signal interaction. Dark
mode uses an emerald glow over near-black green. Light mode uses a real
hairline ring and neutral green shadow because luminous glow disappears on
off-white.

### Shadow Vocabulary

- **Hero Elevation** (`--beryl-elevation`): an inset hairline plus a large,
  diffuse emerald glow in dark mode; a one-pixel ring plus neutral shadow in
  light mode.
- **Interactive Lift** (`0 14px 40px -18px var(--beryl-glow)`): cards and
  pagination links after a three-pixel upward move.
- **Primary Action Lift** (`0 12px 30px -10px var(--beryl-glow)`): homepage
  primary button hover.
- **Gem Float** (`drop-shadow(0 18px 40px var(--beryl-glow))`): the isolated
  gemstone asset only.

**The Resting-Stone Rule.** Surfaces stay tonally layered and nearly flat at
rest. Glow is earned by focus, hover, or the singular hero object.

## Shapes

Forms are softly cut rather than bubbly. Inline code uses a small five-pixel
curve, icon chips use ten pixels, code frames and tables use twelve pixels,
cards and asides use fourteen pixels, and feature modules use sixteen pixels.
Full pills are reserved for buttons, the pre-1.0 status badge, and short
indicators.

Faceted diamonds and irregular polygons are signature geometry. They appear in
the gemstone asset, blurred hero shards, and small feature markers. They must
remain sparse enough to read as one identity rather than a texture.

**The Facet-Sparing Rule.** Use faceted geometry for brand signatures and
orientation, not as a border or background treatment on every container.

## Components

Components feel tactile, precise, and quietly playful. States use emerald,
morganite, lift, and clear focus rings without changing familiar web
affordances.

### Buttons

- **Shape:** full pill with a 44px minimum touch target.
- **Primary:** emerald fill, dark mineral text, semibold label, and generous
  horizontal padding.
- **Hover / Focus:** two-pixel lift, diffuse emerald shadow, slight saturation,
  and a two-pixel emerald focus outline.
- **Secondary:** transparent fill with a quiet border; hover changes the border
  and label to morganite.
- **Minimal:** underlined text with a generous underline offset; hover changes
  both text and underline to morganite.

### Cards / Containers

- **Corner Style:** softly cut fourteen-pixel radius.
- **Background:** translucent tonal surface.
- **Shadow Strategy:** no resting shadow; hover lifts three pixels and adds an
  emerald ring and glow.
- **Border:** one-pixel theme hairline at rest, emerald on interaction.
- **Internal Padding:** inherited from Starlight; preserve its content rhythm.

### Navigation

Starlight's conventional navigation model remains intact. Active and hover
states use emerald rather than inventing a custom navigation grammar. The site
wordmark uses Unbounded and carries a compact morganite pre-1.0 pill on every
page. Mobile keeps Starlight's standard collapsible behavior and touch targets.

### Code

Expressive Code frames use twelve-pixel corners and a hairline boundary. Inline
code uses a translucent morganite surface with the current theme's strongest
text color. Code wraps rather than clipping or hiding horizontal content.

### Asides

Asides replace Starlight's thick colored side stripe with a full one-pixel
border, subtle tonal tint, fourteen-pixel corners, and contained padding. Note
asides use emerald so the palette does not acquire a generic documentation
blue.

### Tables

Tables use a full hairline container, twelve-pixel corners, a tinted header,
compact cells, and quiet morganite row hover. Borders separate rows without
turning the table into a heavy grid.

## Do's and Don'ts

### Do:

- **Do** keep code and technical content more visually prominent than
  decoration.
- **Do** use emerald for links, focus, selection, and interactive structure.
- **Do** reserve morganite for small, high-signal brand moments.
- **Do** preserve the readable Hanken Grotesk body and familiar Starlight
  navigation model.
- **Do** provide purpose-built dark and light treatments with WCAG AA contrast.
- **Do** disable decorative movement under `prefers-reduced-motion`.

### Don't:

- **Don't** spread Unbounded across paragraphs, dense controls, or long
  navigation labels.
- **Don't** add generic blue accents, gradient text, or unrelated SaaS colors.
- **Don't** turn the interface into a grid of identical icon cards.
- **Don't** apply glow to every resting surface.
- **Don't** use faceted geometry as repeated wallpaper.
- **Don't** trade code legibility or documentation scanability for brand
  expression.
