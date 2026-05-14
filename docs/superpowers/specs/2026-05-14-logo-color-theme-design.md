# Logo-based website color theme design

## Problem

The website currently uses a pink-forward Starlight theme, while the beryl logo is primarily green with a narrow pink crystal shard. The site theme should feel derived from the logo rather than dominated by pink.

## Approved approach

Use a forest-green primary theme with restrained pink accents. The theme should draw from the logo's dark forest greens, mid emerald greens, bright lime facets, pale mint highlights, and vivid pink shard.

## Scope

- Update the Starlight theme tokens in `website/src/styles/custom.css`.
- Keep the existing logo image, favicon, layout, docs content, and Astro/Starlight configuration unchanged.
- Preserve accessibility by using high-contrast foreground/background pairs.
- Use pink sparingly for accent states so the theme remains mostly green.

## Theme behavior

Dark mode should use deep forest-green surfaces, pale mint text tones, emerald borders, and a muted logo-pink accent for interactive emphasis.

Light mode should use white or mint-tinted backgrounds, forest-green text/navigation colors, soft green grays, and restrained pink accents for links or selected states.

## Components and data flow

The change is token-only. Starlight consumes the CSS custom properties from `custom.css`, so updating those variables will propagate through navigation, content, links, sidebars, and code-adjacent UI without component edits.

## Error handling

No runtime error handling is required. The main risk is inadequate color contrast, so selected token pairs should remain readable in both light and dark themes.

## Testing

Run the existing website Astro check and site build after implementation.
