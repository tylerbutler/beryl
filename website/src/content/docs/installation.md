---
title: Installation
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. The API is unstable and features may be removed in minor releases.
:::

Add beryl to your Gleam project:

```bash
gleam add beryl
```

This adds beryl to your `gleam.toml` dependencies. beryl targets the **Erlang (BEAM)** runtime — it does not support the JavaScript target.

## Packages

A typical application adds three packages: the core, a programming layer, and a WebSocket transport.

| Package | Add it when |
|---------|-------------|
| `beryl` | Always — the runtime, wire codec, presence, PubSub, groups, and the app-side dispatch API |
| `beryl_channels` | You want the [channel layer](/guides/channels/), the recommended default for multi-channel and Phoenix-shaped apps |
| `beryl_mist` | You serve HTTP with [Mist](https://hex.pm/packages/mist) |
| `beryl_ewe` | You serve HTTP with [Ewe](https://hex.pm/packages/ewe) |

```bash
# Channel layer on Mist — the recommended default
gleam add beryl beryl_channels beryl_mist

# Raw app-side dispatch on Mist
gleam add beryl beryl_mist
```

`beryl_channels` depends on `beryl` plus the shared Gleam libraries beryl
already pulls in (`gleam_stdlib`, `gleam_erlang`, `gleam_otp`, `gleam_json`),
so adding it introduces no new transitive runtime dependencies beyond beryl's
existing graph. See [Choose an API](/choosing-an-api/) if you are deciding
between the two layers.

## Requirements

- **Gleam** >= 1.13.0
- **Erlang/OTP** >= 26 (recommended: 27+)
- **Target**: Erlang only

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
