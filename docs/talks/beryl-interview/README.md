# beryl interview deck

[MARP](https://marp.app/) deck for interview/talk appearances about beryl.
`beryl-theme.css` mirrors the website's visual system
(`website/src/styles/custom.css` + `fonts.css`): dark emerald ground,
emerald accent, morganite magenta pop, Unbounded/Hanken Grotesk/JetBrains Mono.

Speaker notes are embedded as HTML comments on each slide — use presenter
view (`p` in the bespoke HTML export, or the Marp VS Code preview).

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

For the VS Code Marp extension, register the theme in settings:

```json
"markdown.marp.themes": ["./docs/talks/beryl-interview/beryl-theme.css"]
```
