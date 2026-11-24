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
- An HTTP/2 WebSocket has a separate lifecycle watcher for its captured
  runtime and stream worker. Runtime exit kills that worker even if flow
  control blocks a write; Ewe resets only that stream and discards its
  unsent buffered output. This does not impose a general write deadline
  (`beryl_ewe.gleam:watch_runtime`).

## Side effects

- `ewe.websocket` handles the connection lifecycle; Ewe text/binary send calls
  write outbound frames (`beryl_ewe.gleam:do_upgrade`,
  `beryl_ewe.gleam:on_message`).
- The force-close callback kills the connection-owner process
  (`beryl_ewe.gleam:force_close`).
- HTTP/2 lifecycle watchers end when their runtime or stream worker exits.
  HTTP/1 keeps its existing selector-based runtime monitor
  (`beryl_ewe.gleam:watch_runtime`, `beryl_ewe.gleam:do_upgrade`).
- Shared server calls perform beryl admission, routing, and disconnect cleanup
  (`beryl_ewe.gleam:upgrade`, `beryl_ewe.gleam:on_message`).

## Verification

From the repository root: `just test beryl_ewe`.
