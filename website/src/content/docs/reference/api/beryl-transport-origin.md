---
title: "beryl/transport/origin"
description: "Origin and handshake-version checks for WebSocket upgrades."
---

Origin and handshake-version checks for WebSocket upgrades.

 Pure string-level checks shared by beryl's WebSocket transports. They
 operate on header and query values, not on server-specific request
 types; `beryl/transport/server` applies them to `gleam/http` requests as
 part of the shared upgrade pipeline.

## Types

### `OriginPolicy`

Policy for validating the browser `Origin` header before a WebSocket
 upgrade completes.

 The `Origin` check is the primary defence against Cross-Site WebSocket
 Hijacking (CSWSH): a browser attaches ambient cookies/session credentials
 to a WebSocket handshake regardless of which site initiated it, so a socket
 that authenticates from those credentials must reject upgrades that
 originate from other sites.

 In every policy, a request with **no** `Origin` header is allowed: browsers
 always send `Origin` on WebSocket handshakes, so an absent header signals a
 non-browser client (native app, server-to-server, CLI) that is not subject
 to the browser same-origin model and cannot be tricked into a cross-site
 upgrade. The one exception is [`AllowList`](#OriginPolicy), which requires a
 matching `Origin` and therefore rejects absent ones.

```gleam
pub type OriginPolicy {
  SameOrigin
  AllowList(List(String))
  AllowAll
}
```

#### Constructors

##### `SameOrigin`

Allow an upgrade only when the request `Origin` authority (host plus any
 port, with the scheme stripped) matches the request `Host` authority.
 This is the default and rejects cross-site upgrades before the handshake.

 A malformed or opaque `Origin` (e.g. `null` from a sandboxed iframe, or a
 value with no host) is rejected. Comparison is over the full `host:port`
 authority, so a non-default port must match on both sides.

 Behind a reverse proxy this compares against the `Host` header as the app
 sees it: ensure the proxy forwards the public `Host` unchanged, or use
 [`AllowList`](#OriginPolicy) with the public origins instead. Forwarded
 headers such as `X-Forwarded-Host` are not trusted, because clients can
 spoof them.

##### `AllowList(List(String))`

Allow an upgrade only when the request `Origin` header matches one of the
 listed values exactly (including scheme, host, and any port), such as
 `"https://app.example.com"`. Requests without an `Origin` header, or with
 a non-matching one, are rejected.

##### `AllowAll`

Allow every upgrade regardless of `Origin`. This is an explicit opt-out
 of CSWSH protection: only use it for sockets that do not rely on ambient
 browser credentials (or that authenticate every message independently).

## Functions

### `allowed`

Decide whether an upgrade is allowed under the configured origin policy.

 `origin` and `host` are the request's `Origin` and `Host` header values,
 `None` when the header is absent. A request with no `Origin` header is
 admitted for `SameOrigin` and `AllowAll` (non-browser clients omit
 `Origin`), but rejected for `AllowList`, which requires an explicit match.

```gleam
pub fn allowed(
  policy: OriginPolicy,
  origin: option.Option(String),
  host: option.Option(String)
) -> Bool
```

### `vsn_supported`

Check a client's requested wire protocol version (the `?vsn=` query
 parameter sent by Phoenix clients) before upgrading.

 Beryl speaks the Phoenix V2 array framing, so `vsn=2.x` is accepted. A
 missing `vsn` (`None`) is accepted for non-Phoenix clients speaking the
 configured codec. Anything else (e.g. the V1 object framing's `vsn=1.0.0`)
 is rejected — transports fail the handshake with `403 Forbidden` instead
 of accepting a connection whose every frame would be undecodable.

```gleam
pub fn vsn_supported(vsn: option.Option(String)) -> Bool
```
