# Presence client adapters

## Overview

The Lustre client uses these local channel, presence, and Phoenix adapters.
Phoenix itself comes from the example's npm dependency.

## Interface

- `channel.gleam:Client`, `Event`, `PushError`, `connect`, `push`, and `close`
  expose channel lifecycle and callback delivery.
- `presence.gleam:PresentUser`, `Presence`, `PresenceEvent`, `PresenceError`,
  `new`, `decode_state`, `decode_diff`, `update`, and `present_users`
  expose roster state and decoding.
- `phoenix.gleam:new_socket`, `channel`, `push`, and the lifecycle/subscription
  wrappers expose Phoenix FFI access;
  `phoenix_ffi.mjs` implements them with the imported Phoenix package.

## Invariants

- `presence.gleam:decode_state` and `decode_diff` require `name`, `avatar_url`,
  and `phx_ref` metadata.
- `presence.gleam:update` deduplicates joins by `phx_ref`, removes matching
  references on leave, and removes entries with no remaining references.
- `channel.gleam:connect` decodes channel messages before delivering events.

## Side effects

- `channel.gleam:connect`, `push`, and `close` open connections, register
  callbacks, send messages, and remove subscriptions through the JavaScript FFI.
- `phoenix_ffi.mjs` also disconnects and leaves on `pagehide`.

## Verification

From the repository root: `cd examples/lustre_presence/client && gleam build`.
The parent example's `pnpm build:client` also checks browser bundling.
