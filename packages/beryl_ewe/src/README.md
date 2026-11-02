# Ewe adapter source

## Overview

`beryl_ewe` adapts Ewe WebSockets to beryl's shared transport server. The
package manifest owns the Ewe dependency; shared admission and frame policy
come from `beryl/transport/server`.

## Interface

- `upgrade(request, channels, config, next)` performs an upgrade or calls the
  supplied continuation (`beryl_ewe.gleam:upgrade`).
- `handler(channels, config, http_fallback)` combines WebSocket handling with
  regular HTTP handling (`beryl_ewe.gleam:handler`).
- Callers use the imported `server.TransportConfig` builders; this adapter
  defines no separate configuration type (`beryl_ewe.gleam:upgrade`).

## Invariants

- CONNECT requests without Host get a Host value from the request host and
  optional port. Other requests retain their headers
  (`beryl_ewe.gleam:upgrade`).
- The combined handler sends CONNECT and recognized WebSocket requests through
  upgrade; other requests use the HTTP fallback (`beryl_ewe.gleam:handler`).
- Peer IP extraction accepts TCP addresses and rejects Unix socket addresses
  (`beryl_ewe.gleam:request_ip`).
- Connection initialization uses the configured codec through the shared
  server. Message handling forwards text/binary frames to that server and
  reports outbound write completion (`beryl_ewe.gleam:do_upgrade`,
  `beryl_ewe.gleam:on_message`).

## Side effects

- `ewe.websocket` handles the connection lifecycle; Ewe text/binary send calls
  write outbound frames (`beryl_ewe.gleam:do_upgrade`,
  `beryl_ewe.gleam:on_message`).
- The force-close callback kills the connection-owner process
  (`beryl_ewe.gleam:force_close`).
- Shared server calls perform beryl admission, routing, and disconnect cleanup
  (`beryl_ewe.gleam:upgrade`, `beryl_ewe.gleam:on_message`).

## Verification

From the repository root: `just test beryl_ewe`.
