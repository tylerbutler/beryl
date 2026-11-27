# Gleam Plugin

Gleam-specific development skills and agents.

## Skills

- `gleam-review` - load whenever a task targets `.gleam` source, test, or example files. Apply the official Gleam conventions, patterns, and anti-patterns guide (bundled in `skills/gleam-review/references/conventions.md`) during development. Explicit code-review requests remain report-only unless fixes are requested.
- `gleam-reference-docs` - wire up a repeatable workflow that turns `package-interface.json` from `gleam docs build` into Markdown reference pages for a docs site (Astro/Starlight-oriented), including the generator script in `skills/gleam-reference-docs/assets/`.
- `changelog-authoring` - author Trellis changelog fragments with complete sentence headings and explanatory paragraphs. Inspect each repository's tool version, configuration, packages, and renderer before choosing literal output; verify native previews and exclude documentation/development-only changes. Requires Trellis; does not install or configure changelog tooling.

The `changelog-authoring` skill adapts Beryl's first-party [canonical skill](https://github.com/tylerbutler/beryl/blob/5337faba77529c40361bc80e2167fc0c638d1a94/.apm/skills/changelog-authoring/SKILL.md), including the corrected non-bullet renderer guidance. It replaces Beryl-specific package names, release rules, and task recipes with repository discovery. Its MIT license and copyright notice are in `skills/changelog-authoring/LICENSE`.

## Agents

- `erlang-specialist` - always use when writing, editing, or refactoring Erlang code, including Gleam FFI implementations and Erlang `@external` declarations. Applies Erlang patterns and best practices. Checks existing APIs and maintained typed Gleam dependencies before writing new FFI; uses a suitable typed dependency when available.
- `beam-vm-reviewer` - review Gleam and Erlang code for BEAM VM and OTP runtime defects and opportunities. Covers process lifecycle, mailboxes, supervision, timers, scheduler work, memory, shared state, distribution, and FFI.

The definitions are in `agents/*.agent.md` and are bundled with this plugin for Claude Code and Copilot. The `erlang-specialist` implements changes; the `beam-vm-reviewer` reports runtime findings without editing files.

The `beam-vm-reviewer` is copied unchanged from Beryl's `.github/agents/beam-vm-reviewer.agent.md`. It retains Beryl-specific constraints and test commands.
