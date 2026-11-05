# Transport server support

## Overview

Shared WebSocket admission and connection handling for transport adapters.
`origin` implements policy checks; `server` combines those checks with the
public `beryl/transport` SPI. Adapters supply their HTTP/WebSocket operations.

## Interface

- `origin.OriginPolicy` has `SameOrigin`, `AllowList`, and `AllowAll` variants.
  `allowed` checks a request and `version_supported` checks Phoenix protocol
  versions (`origin.gleam:OriginPolicy`, `origin.gleam:allowed`,
  `origin.gleam:version_supported`).
- Opaque `server.TransportConfig` uses `default_config` and the `with_on_connect`,
  `with_allowed_origins`, `with_allow_all_origins`, and `with_outbound_limits`
  builders (`server.gleam:TransportConfig`, `server.gleam:default_config`,
  `server.gleam:with_outbound_limits`).
- `with_outbound_limits` returns
  `Result(TransportConfig(body), OutboundConfigError)`. Its errors are
  `InvalidMaxOutboundFrames`, `InvalidMaxOutboundBytes`,
  `MaxOutboundFramesTooLarge`, and `MaxOutboundBytesTooLarge`
  (`server.gleam:with_outbound_limits`, `server.gleam:OutboundConfigError`).
- `is_websocket_request`, `upgrade`, and `handler` select admission, rejection,
  or HTTP fallback through supplied callbacks (`server.gleam:upgrade`,
  `server.gleam:handler`, `server.gleam:is_websocket_request`).
- `connect_seed`, `init_connection`, and `close_connection` manage opaque
  `ConnectionState`. `SendRequest` represents outbound text, binary, and close
  requests (`server.gleam:connect_seed`, `server.gleam:init_connection`,
  `server.gleam:close_connection`, `server.gleam:SendRequest`).
- `handle_text_frame`, `handle_binary_frame`, and `finish_outbound_write`
  return `FrameDisposition` so adapters can continue or stop
  (`server.gleam:handle_text_frame`, `server.gleam:handle_binary_frame`,
  `server.gleam:finish_outbound_write`, `server.gleam:FrameDisposition`).

## Invariants

- Same-origin checks compare lowercased host-and-port authorities, ignoring the
  scheme. An absent Origin passes this policy; a present Origin requires a valid
  authority and Host. Allow-list checks use exact full Origin strings and reject
  an absent Origin (`origin.gleam:allowed`, `origin.gleam:same_origin`).
- An absent protocol version passes; a supplied version must begin with `2.`
  (`origin.gleam:version_supported`).
- Defaults use a normalized path, same-origin policy, and outbound ceilings of
  256 frames and 1 MiB. Path matching is exact after normalization
  (`server.gleam:default_config`, `server.gleam:normalize_path`,
  `server.gleam:upgrade`).
- Policy/version checks precede slot acquisition. Authentication rejection
  releases the permit; connect metadata preserves order and duplicate keys
  (`server.gleam:handle_matched_upgrade`, `server.gleam:run_on_connect`).
- Oversized frames stop the connection. Rate-limited or undecodable frames drop
  without stopping it; runtime admission rejection stops it
  (`server.gleam:handle_text_frame`, `server.gleam:handle_binary_frame`,
  `server.gleam:finish_route`).
- Outbound writes reserve retained bytes. Finishing a write releases its
  reservation; a failed write returns `Stop`
  (`server.gleam:SendRequest`, `server.gleam:finish_outbound_write`).
- Outbound configuration accepts 1 through 8,388,607 frames and 1 through
  1,099,511,627,775 bytes. Nonpositive or oversized values return an error
  (`server.gleam:with_outbound_limits`).

## Side effects

- Admission acquires/releases connection permits, emits telemetry, and invokes
  authentication and upgrade/rejection callbacks
  (`server.gleam:handle_matched_upgrade`, `server.gleam:finish_upgrade`).
- Connection initialization creates process subjects/selectors, binds permits,
  monitors the runtime, and registers the socket. Failure or outbound exhaustion
  invokes the adapter's force-close callback (`server.gleam:init_connection`).
- Frame handlers route work to the runtime and emit diagnostics. Cleanup
  cancels outbound reservations, announces disconnect, and releases the permit
  (`server.gleam:handle_text_frame`, `server.gleam:handle_binary_frame`,
  `server.gleam:close_connection`).

## Verification

From the repository root: `just test beryl`. For the core FFI boundary:
`just beam-check`.
