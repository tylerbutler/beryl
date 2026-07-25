---
name: gleam-review
description: Review Gleam code against the official Gleam conventions, patterns, and anti-patterns guide. Identifies anti-patterns (check-then-assert, catch-all matches, panicking in libraries, abbreviations, fragmented modules), convention violations (unqualified imports, missing type annotations, fallible functions that don't return Result), and opportunities to apply recommended patterns (descriptive errors, invalid-states-impossible modelling, builder pattern). Manual invocation only — run via /gleam-review, optionally with files, directories, or package names as arguments.
disable-model-invocation: true
---

# Gleam Code Review

Review Gleam code against the official Gleam style guide. The full guide is in
`references/conventions.md` — read it in its entirety before reviewing, every
time. It is the authority for this review; do not substitute general
functional-programming intuitions for what it actually says.

This is a review, not a refactor: report findings and stop. Only apply fixes
if the user asks for them afterward.

## Determine scope

Use the first of these that applies:

1. Arguments were given (file paths, directories, or package names) — review
   those. A bare name like `lattice_core` means that package's `src/` and
   `test/` directories.
2. There are uncommitted changes — review the changed `.gleam` files
   (`git status` / `git diff`).
3. The current branch differs from `main` — review the `.gleam` files changed
   on the branch (`git diff main...HEAD --name-only`).
4. Otherwise, ask the user what to review.

Read each in-scope file completely, not just the changed hunks. Most findings
in this guide (fragmented modules, error-type design, catch-all matches) only
make sense with the whole module in view, and a diff-only reading produces
false positives — e.g. flagging a "missing" annotation that is actually
present two lines above the hunk.

## How to classify findings

The guide defines three tiers, and the report must keep them distinct because
they carry different weight:

- **Conventions** and **anti-patterns** are always-rules. Deviations are
  violations — report every one you find.
- **Patterns** (descriptive errors, invalid-states-impossible, builder,
  sans-io, etc.) are judgment calls. Report a pattern only as a suggestion,
  and only where applying it would clearly improve the specific code at hand.
  A missing pattern is not a violation.

Judgment notes that prevent false positives:

- Formatting is `gleam format`'s job. Never report layout, line length, or
  indentation.
- `let assert` and panics are forbidden in library `src/` code, but are
  acceptable in `test/` code (a failed assertion failing the test is the
  point) and at the top level of application code.
- A catch-all `_` pattern over an open-ended type (`Int`, `String`, lists) is
  often unavoidable; the anti-pattern is catch-alls over custom types with a
  small closed set of variants, where exhaustive matching was possible.
- Short variable names are abbreviations only if they abbreviate something: a
  generic `a` in a generic function, or an idiomatic accumulator in a
  one-line fold, is not in the same class as `cnt`, `cfg`, or `proc_dat`.
- Before flagging fragmented modules or namespace issues, look at the actual
  package layout — module-boundary findings need the directory structure as
  evidence, not just one file's imports.

When unsure whether something violates the guide, re-read the relevant
section of `references/conventions.md` and quote it in the finding. If it is
still genuinely ambiguous, leave it out — a review full of maybes buries the
real findings.

The guide is the charter, but do not stay silent about clearly broken code
you happen to read while reviewing: code that won't compile, corrupts data
(e.g. building JSON by string concatenation without escaping), or crashes on
ordinary input. Flag these in a short "Out of scope, but notable" section —
one or two lines each, no deep bug-hunting. This is a courtesy flag for
things you tripped over, not a second review dimension; if the user wants a
correctness review, that is a different task.

## Report format

Lead with a one-paragraph verdict: overall state of the code and the most
important finding. Then:

```markdown
## Violations
<!-- Conventions broken + anti-patterns present. Omit section if none. -->
- `path/file.gleam:12` — **<Guide section name>**: what the code does, why
  the guide forbids it, and what to do instead (with a short code sketch
  when the fix isn't obvious).

## Suggestions
<!-- Patterns worth applying + borderline judgment calls. Omit if none. -->
- `path/file.gleam:40` — **<Pattern name>**: what would improve and why it
  is worth it here.

## Out of scope, but notable
<!-- Obvious correctness bugs tripped over while reading: won't compile,
     data corruption, crashes. One or two lines each. Omit if none. -->

## Notable
<!-- 1-3 things the code does well, only if genuinely notable. -->
```

Order findings by importance, not file order. Name each finding after the
guide section it comes from (e.g. **Check-then-assert**, **Match all
variants**) so the user can look it up. Every finding needs a `file:line`
reference. If the code is clean, say so plainly — do not manufacture findings
to make the review look thorough.
