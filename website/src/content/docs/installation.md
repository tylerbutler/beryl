---
title: Installation
---

:::note[Pre-1.0]
beryl is pre-1.0: the API can change between minor releases and it isn't production-hardened yet. Build with it and tell us what breaks; that feedback is shaping 1.0.
:::

beryl is not yet published to Hex. Add it to your Gleam project as a git
dependency by editing `gleam.toml`:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl" }
beryl_mist = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_mist" }
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
7 | beryl = { git = "...", ref = "main", path = "packages/beryl" }
  |         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
data did not match any variant of untagged enum Requirement
```

If you see `data did not match any variant of untagged enum Requirement`,
upgrade Gleam.

## Choosing a ref

`ref = "main"` gives you the code this site documents. Everything here — the
Quick Start, the guides, the generated API reference — describes `main`, so
that is the recommended ref until the next tag lands. Git dependencies resolve
at the exact ref you name, and `main` moves, so rerun `gleam deps download`
deliberately when you want to pick up changes. Use the same `ref` for `beryl`
and its transport package — mixing versions across the two is unsupported.

If you'd rather pin an immutable ref, use a commit SHA from
[`main`'s history](https://github.com/tylerbutler/beryl/commits/main) — you
keep the documented API and control exactly when you move.

:::note[About the `v0.0` tag]
The only released tag, [`v0.0`](https://github.com/tylerbutler/beryl/releases),
is a preview from before these docs. Its API differs from what this site
describes — most visibly, it still has the unsupervised `beryl.start` path
that `main` replaced with `beryl.child_spec` and OTP supervision (see the
[Supervision guide](/guides/supervision/)). Don't pin it unless you're
deliberately using that older API.
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
