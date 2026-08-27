---
title: Installation
---

:::note[Pre-1.0]
beryl is not yet version 1.0. Minor releases can change the API. The library is
not ready for production. Try it and report problems. Your feedback will help
define version 1.0.
:::

Install beryl packages from
[GitHub](https://github.com/tylerbutler/beryl). They are not on Hex. Add them
as Git dependencies in `gleam.toml`:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl" }
beryl_mist = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_mist" }
```

Download the dependencies:

```bash
gleam deps download
```

`gleam add` installs only Hex packages. Add these entries by hand.

`beryl` includes the core runtime and the recommended `beryl/channel` API.
`beryl_mist` provides the [Mist](https://hex.pm/packages/mist) WebSocket
transport. For [Ewe](https://hex.pm/packages/ewe), use
`path = "packages/beryl_ewe"`. Use the same `git` and `ref` values for all
packages.

beryl supports only the **Erlang (BEAM)** target. It does not support the
JavaScript target.

## Packages

A typical application needs beryl and one WebSocket transport.

| Package | Add it when |
|---------|-------------|
| `beryl` | Always — the runtime, raw dispatch API, `beryl/channel`, wire codec, presence, PubSub, and groups |
| `beryl_mist` | You serve HTTP with [Mist](https://hex.pm/packages/mist) |
| `beryl_ewe` | You serve HTTP with [Ewe](https://hex.pm/packages/ewe) |

Import `beryl/channel` for the recommended channel model, or `beryl/socket`
for raw dispatch. See [Choose an API](/choosing-an-api/) for the tradeoff.

## Requirements

- **Gleam** >= 1.18.0
- **Erlang/OTP** >= 26 (recommended: 27+)
- **Target**: Erlang only

### Why Gleam 1.18?

beryl is a monorepo. Its packages are in the `packages/beryl`,
`packages/beryl_mist`, and `packages/beryl_ewe` subdirectories. Git
dependencies use the `path` field to select a subdirectory. Gleam added this
field in version 1.18. Older versions can select only the repository root and
cannot install beryl.

This requirement applies to the Gleam version that installs beryl. The packages
declare `gleam = ">= 1.13.0"` and can compile with older toolchains. You need
Gleam 1.18 only to use the dependency entries above.

On an older Gleam, `gleam deps download` fails while parsing your `gleam.toml`
rather than reporting a version problem:

```
error: File IO failure

An error occurred while trying to parse this file:

    gleam.toml

  |
7 | beryl = { git = "...", ref = "main", path = "packages/beryl" }
  |         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
data did not match any variant of untagged enum Requirement
```

If you see `data did not match any variant of untagged enum Requirement`,
upgrade Gleam.

## Pin a Git ref

The example uses `main`, which matches these docs. The branch can change without
warning. Check [GitHub Releases](https://github.com/tylerbutler/beryl/releases).
When one tag contains all required packages, replace `main` with that tag.

Gleam resolves Git dependencies at the specified ref. Use the same ref for
`beryl` and its transport package. Do not mix versions.

## Packages installed with beryl

beryl brings in these Gleam packages automatically:

| Package | Purpose |
|---------|---------|
| `gleam_stdlib` | Standard library |
| `gleam_erlang` | Erlang interop |
| `gleam_otp` | OTP actors |
| `gleam_json` | JSON encoding/decoding |
| `gleam_crypto` | Socket ID generation |
| `lattice_presence` | CRDT-backed presence tracking |
| `palabres` | Structured logging |
