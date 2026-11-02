# Mist adapter source

## Overview

`beryl_mist` adapts Mist WebSockets to beryl's shared transport server. Mist
and glisten belong to this package's dependencies; beryl owns admission policy,
frame processing, and runtime routing.

## Interface

- `upgrade(request, channels, config, next)` attempts a WebSocket upgrade
  (`beryl_mist.gleam:upgrade`).
- `handler(channels, config, http_fallback)` combines socket and HTTP handling
  (`beryl_mist.gleam:handler`).
- Configuration uses imported `server.TransportConfig`; the adapter defines
  no separate configuration type (`beryl_mist.gleam:upgrade`).

## Invariants

- Peer IP comes from Mist connection information (`beryl_mist.gleam:request_ip`).
- The combined handler delegates upgrade/fallback selection to the shared
  server (`beryl_mist.gleam:handler`).
- Connection initialization uses the shared configured codec. Text/binary
  messages delegate frame policy to the shared server; `Closed`, `Shutdown`,
  and a server close request stop the adapter
  (`beryl_mist.gleam:do_upgrade`, `beryl_mist.gleam:on_message`).
- Outbound send results pass to `server.finish_outbound_write`
  (`beryl_mist.gleam:on_message`).

## Side effects

- `mist.websocket` handles connection lifecycle; Mist text/binary send calls
  write frames (`beryl_mist.gleam:do_upgrade`, `beryl_mist.gleam:on_message`).
- Force-close calls `glisten_transport.close`. Already-closed and not-connected
  results count as success; other errors return `ForceCloseFailed`
  (`beryl_mist.gleam:force_close`).
- Shared server calls perform beryl admission, routing, and cleanup
  (`beryl_mist.gleam:upgrade`, `beryl_mist.gleam:on_message`).

## Verification

From the repository root: `just test beryl_mist`.
