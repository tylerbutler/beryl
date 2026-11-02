# Presence server source

## Overview

The server wires signed-cookie authentication into the WebSocket transport and
dashboard channel.

## Interface

- `lustre_presence.gleam:main` starts the application.
- [Server modules](./lustre_presence/README.md) own cookies, users, channel
  authorization, and HTTP routing.

## Invariants

- `lustre_presence.gleam:main` shares one startup secret between HTTP cookie
  validation and WebSocket `on_connect`.
- Rejected handshakes do not receive authenticated channel metadata.
- The entry point configures frame/message/join/connection rates and caps.

## Side effects

`lustre_presence.gleam:main` generates the secret, starts supervision and Mist
on port 8002, prints startup URLs, and sleeps indefinitely.

## Verification

From the repository root: `cd examples/lustre_presence && gleam build`.
`pnpm -C examples/lustre_presence test` runs Node tests and Gleam tests.
