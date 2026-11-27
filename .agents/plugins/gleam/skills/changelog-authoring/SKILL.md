---
name: changelog-authoring
description: Use when creating or editing changelog fragments or release entries in a Gleam project using Trellis, or deciding whether a change needs an entry. Inspect the repository's current configuration and renderer, then write valid TOML with a complete sentence heading and explanatory paragraphs. Exclude documentation-only and development-only changes.
compatibility: Gleam projects using Trellis changelog tooling; requires inspecting the consuming repository's installed tool version and configuration.
license: MIT
---

# Changelog authoring

## Inspect the consuming repository

Read repository instructions, the root and affected packages' `gleam.toml`,
tool pins, existing fragments, and changelog/check recipes in the `justfile`
or other task runner. Identify the installed Trellis version through the
repository's existing tool environment and inspect its CLI help before using
commands or flags from this skill.

Read `[tools.trellis.changelog]`, including kinds, bump mappings, categories,
strictness, fragment paths, and renderer settings such as `change_format` and
`dependency_body`. Inspect release exclusions, publish lifecycle, and bundle
ownership to learn which packages release independently.

Use the current configuration and tool version as the authority. Existing
fragments and historical output can predate renderer changes; they are not
proof that a format still works. If the repository uses another changelog
tool, explain that this skill requires Trellis and stop. Do not install
Trellis, replace the tool, or invent configuration or wrapper commands.

## Decide whether an entry is required

Add entries for user-facing code changes in released packages: public API,
observable runtime behavior, bug fixes, performance, security, or runtime
dependency requirements. Describe what consumers receive.

Do not add entries for documentation-only changes, including `///` and `////`
source comments and package documentation. Exclude development, test, CI,
tooling, website, example, and benchmark changes, and refactors or formatting
with no consumer-visible effect. In a mixed change, document only its
user-facing code/API effects.

Check for existing fragments covering the change before creating another.
Use the actual package names and create an entry for each affected released
package. Attribute bundled packages' consumer-visible changes to their
releasing owner according to the repository's publish configuration. Do not
create fragments for workspace members excluded from releases. For a package's
first release, follow the repository's initial-release policy.

## Choose the kind and bump

Use exact configured kind labels and categories; do not assume `Fixed`,
`Changed`, `Breaking`, or any other label exists. Read the bump mapping instead
of inferring it from a commit prefix or kind name.

A breaking change needs migration guidance and a verified release bump.
Do not assume `Changed` or `Removed` implies major. Use the repository's
supported version-plan override when needed; a read-only preview does not
save that override. Check initial-release and pre-1.0 behavior against the
installed Trellis version and repository release policy.

## Write the fragment source

For the verified Trellis schema, each fragment is a TOML document with three
required string fields: `package`, `kind`, and nonempty `body`. The only
optional field is `category`; omit it when the repository has no categories.
Confirm this schema against the consuming repository's tool version. Do not
borrow Changie fields or add `summary`, `details`, `bump`, `project`, dates,
or source metadata.

Use native fragment creation and the configured directory. The source uses
`.changes/unreleased/<package>-<body-slug>.toml` in the reference repository;
verify the path locally instead of assuming it. Trellis derives the slug
from the body and adds collision suffixes such as `-2`. Keep the generated
filename. Do not edit generated package changelogs or release archives to
record a new change, and preserve historical changelogs.

The `body` contains the entry's Markdown prose. Write a sentence-case,
complete sentence heading, a blank line, and one or more explanatory
paragraphs. State what changed and its user impact. For an API break, explain
what callers must replace and how. Avoid bare titles, commit-message
fragments, and internal implementation logs. Use the consuming project's
product naming conventions.

### Match the renderer before choosing literal Markdown

With a confirmed non-bullet renderer that places entries under `### Kind`,
use an unindented `####` heading followed by a blank line and unindented
paragraphs. Start any code fences at the beginning of the line too. Do not
add a list marker or indent the body as a list item. Do not use `##` for an
entry: Trellis reserves that level for release versions.

The reference repository uses
`change_format = "{{ body | trim }}\n\n"`; its template supplies blank lines
between entries. Its `dependency_body` also uses an H4 heading and paragraphs.
These settings describe a compatible renderer, not universal defaults.

Keep fragment source and rendered output distinct. A template that prefixes
`- ` can turn a source `####` into `- ####`, which is not the required
standalone heading. Do not prescribe plain bullets or indented H4 bodies as
a workaround. If the current renderer cannot produce the required
heading-and-paragraph shape, report the mismatch and seek approval before
changing renderer configuration. Do not rewrite historical output.

### Serialize Markdown as TOML

Prefer a multiline literal string (`'''`) for Markdown. Quotes, backticks,
backslashes, and line breaks stay literal; TOML removes the newline immediately
after the opening delimiter. If the body contains `'''`, use a multiline
basic string (`"""`) and escape backslashes as `\\` and double quotes as `\"`
as needed. A single-line basic string can use `\n` for line breaks.

This illustrative fragment assumes a released package named `example_library`,
a configured `Fixed` kind, and the compatible non-bullet renderer above.
Adapt those values; do not record this example as a real change.

```toml
package = "example_library"
kind = "Fixed"
body = '''
#### Connection cleanup releases its slot.

Closed connections no longer count against the connection limit. Clients
can reconnect without waiting for the application to restart.
'''
```

A routine fix needs no code sample. Include a short fenced sample only for
an API change and only when it makes usage or migration clearer. Verify its
identifiers against the changed API. Internal, CI, and tooling changes need
no entry or sample. TOML and shell examples here illustrate authoring syntax,
not code samples for release notes.

## Create, preview, and validate

Prefer the repository's native creation recipe after inspecting its quoting.
For multiline Markdown, the direct command can avoid a wrapper's additional
shell expansion of backticks and double quotes. For versions supporting this
syntax, an illustrative command is:

```sh
trellis changelog new --package example_library --kind Fixed --body '#### Connection cleanup releases its slot.

Closed connections no longer count against the connection limit. Clients
can reconnect without waiting for the application to restart.'
```

Adapt the package and kind. Inspect the generated file and use the preferred
literal TOML serialization when editing it. The native command trims the
body; with the compatible template above, entry separation belongs to the
template and needs no trailing blank line in the body.

Keep shell quoting separate from TOML escaping. Do not interpolate untrusted
entry text into shell commands; use an editor or a supported safe input
mechanism when the text cannot be passed as a literal argument.

Run the repository's native changelog check with its actual comparison base.
For a version supporting the reference CLI, this is
`trellis changelog check --base <comparison-base>`. If it supports
`--format json`, inspect the returned `preview` string to check actual
rendering. That preview covers the branch's entries, not the full accumulated
release. Do not assume `origin/main` or a `just changelog-check` recipe exists.

Run the supported read-only version plan and workspace doctor, through
existing recipes when available, to check version effects and fragment
validity. Use prerelease modes or bump overrides only when the consuming
repository's release state and policy require them. Do not run `version
apply`, `release pr`, tag, or publish operations to check prose.

Inspect the preview for a standalone heading, a blank line, explanatory
paragraphs, entry separation, and any useful API sample. With the compatible
renderer and illustrative fragment above, expect:

```markdown
### Fixed

#### Connection cleanup releases its slot.

Closed connections no longer count against the connection limit. Clients
can reconnect without waiting for the application to restart.
```

Path-based coverage checks can warn about documentation-only package changes.
Do not create an unnecessary fragment to silence an advisory warning. Invalid
fragments still need correction. If native tooling is unavailable or a
preview fails, report the blocker; do not claim rendered output is verified.

This plugin owns the reusable skill under `skills/changelog-authoring/`.
Do not edit installed/generated copies or deploy it into consumer repositories
unless the user asks.

Adapted from Beryl's first-party
[canonical skill at commit 5337faba77529c40361bc80e2167fc0c638d1a94](https://github.com/tylerbutler/beryl/blob/5337faba77529c40361bc80e2167fc0c638d1a94/.apm/skills/changelog-authoring/SKILL.md).
See the bundled `LICENSE` for the original MIT notice.
