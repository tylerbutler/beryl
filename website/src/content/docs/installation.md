---
title: Installation
---

:::note[Pre-1.0]
beryl is pre-1.0: the API can change between minor releases and it isn't production-hardened yet. Build with it and tell us what breaks; that feedback is shaping 1.0.
:::

Beryl packages are currently distributed from
[GitHub](https://github.com/tylerbutler/beryl), not Hex. Add them to your
Gleam project as git dependencies by editing `gleam.toml`:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl" }
beryl_channels = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_channels" }
beryl_mist = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_mist" }
```

Then download the dependencies:

```bash
gleam deps download
```

`gleam add` only installs Hex packages, so these dependency entries must be
written by hand.

`beryl` is the core runtime, `beryl_channels` is the recommended programming
layer for multi-channel apps, and `beryl_mist` is the
[Mist](https://hex.pm/packages/mist) WebSocket transport. If you prefer
[Ewe](https://hex.pm/packages/ewe), use `path = "packages/beryl_ewe"` instead.
All packages share the same `git` and `ref` values.

beryl targets the **Erlang (BEAM)** runtime — it does not support the JavaScript target.

## Packages

A typical application adds three packages: the core, a programming layer, and a WebSocket transport.

| Package | Add it when |
|---------|-------------|
| `beryl` | Always — the runtime, wire codec, presence, PubSub, groups, and the app-side dispatch API |
| `beryl_channels` | You want the [channel layer](/guides/channels/), the recommended default for multi-channel and Phoenix-shaped apps |
| `beryl_mist` | You serve HTTP with [Mist](https://hex.pm/packages/mist) |
| `beryl_ewe` | You serve HTTP with [Ewe](https://hex.pm/packages/ewe) |

For raw app-side dispatch on Mist, use the same dependency block without the
`beryl_channels` line.

`beryl_channels` depends on `beryl` plus the shared Gleam libraries beryl
already pulls in (`gleam_stdlib`, `gleam_erlang`, `gleam_otp`, `gleam_json`),
so adding it introduces no new transitive runtime dependencies beyond beryl's
existing graph. See [Choose an API](/choosing-an-api/) if you are deciding
between the two layers.

## Requirements

- **Gleam** >= 1.18.0
- **Erlang/OTP** >= 26 (recommended: 27+)
- **Target**: Erlang only

### Why Gleam 1.18?

beryl is a monorepo: the packages live in subdirectories (`packages/beryl`,
`packages/beryl_channels`, `packages/beryl_mist`, `packages/beryl_ewe`) rather
than at the repository root.
Pointing a git dependency at a subdirectory needs the `path` field, which Gleam
added in 1.18. Gleam 1.17 and earlier have no way to point a git dependency at
anything but the repository root, so beryl cannot be used as a dependency from
those versions.

This is a requirement on *your* Gleam, not on beryl's code: the packages
themselves declare `gleam = ">= 1.13.0"` and compile fine on older toolchains.
1.18 is only what it takes to write the dependency line above.

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

## Choosing a ref

The channel layer has not appeared in a GitHub release tag yet, so the example
uses `main`, which matches these docs but can change without warning. Check
[GitHub Releases](https://github.com/tylerbutler/beryl/releases); once a tag
contains every package you use, replace `main` with that tag.

Git dependencies are resolved at the exact ref you name. Always use the same
ref for `beryl`, `beryl_channels`, and the transport package; mixing versions
across them is unsupported.

## Dependencies

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
