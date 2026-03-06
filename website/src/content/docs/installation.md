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

## Requirements

- **Gleam** >= 1.1.0
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

For WebSocket support, you'll also need [Wisp](https://github.com/gleam-wisp/wisp):

```bash
gleam add wisp
```
