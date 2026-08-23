# beryl interview deck

[MARP](https://marp.app/) deck for interview/talk appearances about beryl.
`beryl-theme.css` mirrors the website's visual system
(`website/src/styles/custom.css` + `fonts.css`). It uses a dark emerald
background, an emerald accent, a morganite magenta accent, and the
Unbounded, Hanken Grotesk, and JetBrains Mono fonts.

Each slide contains speaker notes in an HTML comment. Use presenter view
(`p` in the bespoke HTML export) or the Marp VS Code preview.

## Presence state-sync demo

`presence-demo.html` is a self-contained, theme-matched companion for the
presence slides. It shows two node panels, messages in transit, and a
"reality" strip. The demo contains three scripted scenarios:

1. **Naive events**: a delayed `leave` that arrives after a `join` incorrectly removes a
   connected user
2. **Node crash**: a crash does not send a leave, so disconnected users remain
3. **Observed-remove CRDT**: the same incorrect message order converges

Open the file directly in a browser. You do not need a server. Press `←` or
`→` to change the step. Press `1`, `2`, or `3` to select a scenario. Run
scenarios 1 and 2 on the
"Online presence is harder than it sounds" slide. Save scenario 3 for the
CRDT slide.

## Present / export

```sh
# Live preview while editing
npx @marp-team/marp-cli --theme-set beryl-theme.css --allow-local-files -w deck.md

# Presentable HTML (open in a browser; press `p` for presenter view)
npx @marp-team/marp-cli --theme-set beryl-theme.css --allow-local-files --bespoke.progress -o deck.html deck.md

# PDF handout
npx @marp-team/marp-cli --theme-set beryl-theme.css --allow-local-files --pdf --pdf-notes -o deck.pdf deck.md
```

`--allow-local-files` is required because the title slide references the logo
at `website/src/assets/beryl.webp`.

For the VS Code Marp extension, add the theme to the settings:

```json
"markdown.marp.themes": ["./docs/talks/beryl-interview/beryl-theme.css"]
```
