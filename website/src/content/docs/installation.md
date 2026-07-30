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

## Choosing a ref

The `ref` above pins the [`v0.0`](https://github.com/tylerbutler/beryl/releases)
tag. Pin a tag rather than a branch: git dependencies are resolved at the exact
ref you name, and beryl is pre-1.0, so tracking `main` can pull in breaking
changes without warning. Use the same `ref` for `beryl` and its transport
package — mixing versions across the two is unsupported.

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
