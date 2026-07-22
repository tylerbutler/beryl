---
title: Installation
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable, features may be removed in minor releases, and quality should not be considered production-ready. We welcome usage and feedback in the meantime!
:::

beryl is not yet published to Hex. Add it to your Gleam project as a git
dependency by editing `gleam.toml`:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "v0.0", path = "packages/beryl" }
beryl_mist = { git = "https://github.com/tylerbutler/beryl.git", ref = "v0.0", path = "packages/beryl_mist" }
```

Then download the dependencies:

```bash
gleam deps download
```

`gleam add` only works with Hex packages, so the dependency has to be written by
hand.

`beryl` is the core channels library. `beryl_mist` is the
[Mist](https://hex.pm/packages/mist) WebSocket transport; if you prefer
[Ewe](https://hex.pm/packages/ewe), use `path = "packages/beryl_ewe"` instead.
Both transports live in the same repository, so they share the `git` and `ref`
values.

beryl targets the **Erlang (BEAM)** runtime — it does not support the JavaScript target.

## Requirements

- **Gleam** >= 1.18.0
- **Erlang/OTP** >= 26 (recommended: 27+)
- **Target**: Erlang only

### Why Gleam 1.18?

beryl is a monorepo: the packages live in subdirectories (`packages/beryl`,
`packages/beryl_mist`, `packages/beryl_ewe`) rather than at the repository root.
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
7 | beryl = { git = "...", ref = "v0.0", path = "packages/beryl" }
  |         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
data did not match any variant of untagged enum Requirement
```

If you see `data did not match any variant of untagged enum Requirement`,
upgrade Gleam.

## Choosing a ref

The `ref` above pins the [`v0.0`](https://github.com/tylerbutler/beryl/releases)
tag. Pin a tag rather than a branch: git dependencies are resolved at the exact
ref you name, and beryl is pre-1.0, so tracking `main` can pull in breaking
changes without warning. Use the same `ref` for `beryl` and its transport
package — mixing versions across the two is unsupported.

:::caution[`v0.0` is behind these docs]
`v0.0` is a preview tag, and the rest of this site documents `main`, which has
moved on. The difference you are most likely to hit: `main` removed the
unsupervised `beryl.start` path. Build Beryl with `beryl.child_spec` and add
the returned specification to your application's OTP supervisor, as the
[Supervision guide](/guides/supervision/) describes.

Pin `ref = "main"` if you want the code these docs describe, accepting that it
can break without warning.
:::

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
