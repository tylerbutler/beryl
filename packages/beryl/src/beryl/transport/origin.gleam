//// Origin and handshake-version checks for WebSocket upgrades.
////
//// Pure string-level checks shared by beryl's WebSocket transports. They
//// operate on header and query values, not on server-specific request
//// types; `beryl/transport/server` applies them to `gleam/http` requests as
//// part of the shared upgrade pipeline.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Policy for validating the browser `Origin` header before a WebSocket
/// upgrade completes.
///
/// The `Origin` check is the primary defence against Cross-Site WebSocket
/// Hijacking (CSWSH): a browser attaches ambient cookies/session credentials
/// to a WebSocket handshake regardless of which site initiated it, so a socket
/// that authenticates from those credentials must reject upgrades that
/// originate from other sites.
///
/// In every policy, a request with **no** `Origin` header is allowed: browsers
/// always send `Origin` on WebSocket handshakes, so an absent header signals a
/// non-browser client (native app, server-to-server, CLI) that is not subject
/// to the browser same-origin model and cannot be tricked into a cross-site
/// upgrade. The one exception is [`AllowList`](#OriginPolicy), which requires a
/// matching `Origin` and therefore rejects absent ones.
pub type OriginPolicy {
  /// Allow an upgrade only when the request `Origin` authority (host plus any
  /// port, with the scheme stripped) matches the request `Host` authority.
  /// This is the default and rejects cross-site upgrades before the handshake.
  ///
  /// A malformed or opaque `Origin` (e.g. `null` from a sandboxed iframe, or a
  /// value with no host) is rejected. Comparison is over the full `host:port`
  /// authority, so a non-default port must match on both sides.
  ///
  /// Behind a reverse proxy this compares against the `Host` header as the app
  /// sees it: ensure the proxy forwards the public `Host` unchanged, or use
  /// [`AllowList`](#OriginPolicy) with the public origins instead. Forwarded
  /// headers such as `X-Forwarded-Host` are not trusted, because clients can
  /// spoof them.
  SameOrigin
  /// Allow an upgrade only when the request `Origin` header matches one of the
  /// listed values exactly (including scheme, host, and any port), such as
  /// `"https://app.example.com"`. Requests without an `Origin` header, or with
  /// a non-matching one, are rejected.
  AllowList(List(String))
  /// Allow every upgrade regardless of `Origin`. This is an explicit opt-out
  /// of CSWSH protection: only use it for sockets that do not rely on ambient
  /// browser credentials (or that authenticate every message independently).
  AllowAll
}

/// Decide whether an upgrade is allowed under the configured origin policy.
///
/// `origin` and `host` are the request's `Origin` and `Host` header values,
/// `None` when the header is absent. A request with no `Origin` header is
/// admitted for `SameOrigin` and `AllowAll` (non-browser clients omit
/// `Origin`), but rejected for `AllowList`, which requires an explicit match.
pub fn allowed(
  policy policy: OriginPolicy,
  origin origin: Option(String),
  host host: Option(String),
) -> Bool {
  case policy {
    AllowAll -> True
    AllowList(origins) ->
      case origin {
        Some(origin_value) -> list.contains(origins, origin_value)
        None -> False
      }
    SameOrigin ->
      case origin {
        // Non-browser clients don't send Origin; they can't be driven into a
        // cross-site upgrade, so admit them.
        None -> True
        Some(origin_value) ->
          case host {
            Some(host_value) -> same_origin(origin_value, host_value)
            // Without a Host header we cannot establish the request's own
            // authority, so fail closed.
            None -> False
          }
      }
  }
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Compare an `Origin` header value against a `Host` header value under the
/// same-origin rule: strip the scheme from the origin and compare its
/// authority (host plus any port) to the host authority, case-insensitively.
///
/// A malformed or opaque origin (no `scheme://host`, e.g. `null`) never
/// matches. Comparison is over the full `host:port` authority, so a
/// non-default port must be present and equal on both sides.
pub fn same_origin(origin: String, host: String) -> Bool {
  case origin_authority(origin) {
    Ok(authority) -> authority == string.lowercase(host)
    Error(Nil) -> False
  }
}

/// Extract the lower-cased authority (`host[:port]`) from an `Origin` header
/// value, stripping the `scheme://` prefix. Returns `Error(Nil)` for values
/// without a scheme-delimited host (malformed or opaque origins such as
/// `null`).
fn origin_authority(origin: String) -> Result(String, Nil) {
  use #(_scheme, rest) <- result.try(string.split_once(origin, "://"))
  // An Origin has no path, but strip a trailing path defensively.
  let authority = case string.split_once(rest, "/") {
    Ok(#(authority, _path)) -> authority
    Error(Nil) -> rest
  }
  case authority {
    "" -> Error(Nil)
    _ -> Ok(string.lowercase(authority))
  }
}

/// Check a client's requested wire protocol version (the `?vsn=` query
/// parameter sent by Phoenix clients) before upgrading.
///
/// Beryl speaks the Phoenix V2 array framing, so `vsn=2.x` is accepted. A
/// missing `vsn` (`None`) is accepted for non-Phoenix clients speaking the
/// configured codec. Anything else (e.g. the V1 object framing's `vsn=1.0.0`)
/// is rejected — transports fail the handshake with `403 Forbidden` instead
/// of accepting a connection whose every frame would be undecodable.
pub fn vsn_supported(vsn vsn: Option(String)) -> Bool {
  case vsn {
    Some(version) -> string.starts_with(version, "2.")
    None -> True
  }
}
