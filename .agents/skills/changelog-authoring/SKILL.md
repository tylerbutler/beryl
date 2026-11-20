---
name: changelog-authoring
description: Use whenever creating or editing required beryl changelog fragments or release entries. Check whether a user-facing code or API change needs an entry, then write valid Trellis TOML with a sentence heading and explanatory paragraphs. Exclude documentation-only and development-only changes.
---

# Changelog authoring

## Decide whether an entry is required

Add entries for user-facing code changes in released packages: public API,
observable runtime behavior, bug fixes, performance, security, or runtime
dependency requirements. Describe what consumers receive.

Do not add entries for documentation-only changes, including `///` and `////`
source comments and package documentation. Exclude development, test, CI,
tooling, website, example, and benchmark changes, and refactors or formatting
with no consumer-visible effect. In a mixed PR, document only the user-facing
code/API changes; do not add entries for its documentation-only parts.

Use `beryl`, `beryl_mist`, or `beryl_ewe` as the package. Each affected released
package needs its own entry. `beryl_protocol` and `beryl_heirloom` ship inside
beryl: record their consumer-visible changes under `beryl`, not their own names.
Examples and benchmarks have no releases or fragments.

## Choose the kind and bump

Read `[tools.trellis.changelog]` in the root `gleam.toml`. Current choices are:

| Kind | Bump | Use |
| --- | --- | --- |
| `Initial Release` | major | Explicit stable initial release; forces 1.0.0 for a 0.x package |
| `Added` | minor | New functionality; also an initial 0.x release |
| `Changed` | minor | Changed behavior or API |
| `Removed` | minor | Removed functionality |
| `Fixed` | patch | Corrected behavior |
| `Performance` | patch | Runtime performance change |
| `Deprecated` | patch | Deprecation and replacement guidance |
| `Security` | patch | Security fix |
| `Dependencies` | patch | Runtime dependency requirement change |

Use exact labels. There is no configured `Breaking` kind. A breaking change
must explain migration. Do not assume `Changed` or `Removed` selects a major
release: release planning must select the required bump explicitly, for example
`just version-plan --bump beryl=major`. A preview does not save that override.

## Write the fragment file

Source files are `.changes/unreleased/<package>-<body-slug>.toml`.
`trellis changelog new` derives the slug from the first words of the body and
adds `-2`, `-3`, and so on for collisions. Keep the generated filename.
Do not edit generated `packages/*/CHANGELOG.md` files or release archives to
record a new change.

Each file is a TOML document with three required string fields:
`package`, `kind`, and nonempty `body`. The only optional field is `category`;
beryl configures no categories, so omit it. Do not add `summary`, `details`,
`bump`, `project`, dates, or source metadata fields.

The `body` contains all rendered prose as Markdown. Use a sentence-case,
complete sentence as a level-four heading (`####`), followed by a blank line
and one or more explanatory paragraphs. State what changed and its user
impact. For an API break, explain what callers must replace and how. Avoid a
bare title, commit-message fragments, or an internal implementation log.
Use short, direct sentences and write the product name as `beryl`.

The repository's `change_format` template renders the body without a list
marker under a `### Kind` heading and adds a blank line between entries.
Keep the `####` heading, paragraphs, and any code fences at column one.
Do not add a list marker or indent the entry as a list item. Do not use `##`:
Trellis reserves that level for release versions. The `dependency_body`
template gives generated dependency entries the same heading-and-paragraph
format.

Prefer a TOML multiline literal string (`'''`) for Markdown. Quotes,
backticks, backslashes, and line breaks stay literal; the newline immediately
after the opening delimiter is removed. If the text contains `'''`, use a
multiline basic string (`"""`) and escape backslashes as `\\` and double
quotes as `\"` as needed. A single-line basic string can use `\n` for line
breaks. These are serialization rules, not extra rendered prose.

These authoring examples illustrate the format, not changes to record now.
A routine fix needs no code sample:

```toml
package = "beryl"
kind = "Fixed"
body = '''
#### Connection cleanup releases its slot.

Closed connections no longer count against the connection limit. Clients
can reconnect without waiting for the application to restart.
'''
```

Include a short fenced code sample only for an API change and only if it
makes usage or migration clearer. Verify identifiers against the changed API.
Do not include code samples in entries for routine fixes or internal, CI, or
tooling changes; the latter changes do not need entries at all. TOML and shell
examples in this skill show authoring syntax, not release-note code samples.
An API rename can include a migration sample:

````toml
package = "beryl"
kind = "Changed"
body = '''
#### The origin policy uses the name SameAuthority.

Replace `transport.SameOrigin` with `transport.SameAuthority`. The policy
still compares the host and port; admission rules do not change.

```gleam
transport.SameAuthority
```
'''
````

## Create, preview, and validate

`just change <package> <kind> "<body>"` wraps `trellis changelog new`.
For multiline Markdown, prefer the direct command with a single-quoted shell
argument, then inspect the generated file. This avoids the wrapper's extra
shell expansion of backticks and double quotes. For example:

```sh
trellis changelog new --package beryl --kind Fixed --body '#### Connection cleanup releases its slot.

Closed connections no longer count against the connection limit. Clients
can reconnect without waiting for the application to restart.'
```

The command trims the body. Use the preferred multiline literal TOML format
when editing the resulting file. The template supplies entry separation;
the body needs no trailing blank line.
Keep shell quoting separate from TOML escaping; do not interpolate untrusted
entry text into a shell command.

Run `just changelog-check` (equivalent to
`trellis changelog check --base origin/main`) for branch coverage.
Use `trellis changelog check --base origin/main --format json` and inspect its
`preview` string for the actual rendered heading, paragraphs, and any sample.
It previews this branch's entries, not the full accumulated release.

Run `just version-plan` to preview version effects, or
`just version-plan --pre rc` / `just version-plan --pre none` when the current
candidate state needs an explicit mode. `just doctor` validates workspace
invariants and fragments. All these commands are read-only; do not run
`version apply`, `release pr`, tag, or publish commands to check entry prose.

The configured check uses `strictness = "warn"` and detects changed package
paths, not user impact. A documentation-only package change can warn without
needing an entry. Invalid fragments still fail. Apply the policy above rather
than creating an unnecessary release to silence an advisory warning.

The preview should contain this shape, with an actual H4 heading rather than
`- ####`:

```markdown
### Fixed

#### Connection cleanup releases its slot.

Closed connections no longer count against the connection limit. Clients
can reconnect without waiting for the application to restart.
```

Edit this skill under `.apm/skills/changelog-authoring/`, then deploy with
`apm install --frozen --only apm`. APM uses the existing `targets` and
`includes: auto` configuration in `apm.yml` to deploy to
`.agents/skills/changelog-authoring/` (Copilot) and
`.claude/skills/changelog-authoring/` (Claude). Do not edit deployed copies.
