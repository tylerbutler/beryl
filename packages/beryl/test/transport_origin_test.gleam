//// Origin policy tests for `beryl/transport/origin`.
////
//// The `SameOrigin` policy strips the scheme from the `Origin` header value
//// and compares the resulting authority (host + optional port) against the
//// request `Host` authority. These live here rather than in a transport
//// package because the policy is beryl-core logic that every transport
//// shares.

import beryl/transport/origin
import gleam/option.{None, Some}
import gleeunit/should

fn same_origin(origin_value: String, host: String) -> Bool {
  origin.allowed(
    policy: origin.SameOrigin,
    origin: Some(origin_value),
    host: Some(host),
  )
}

pub fn same_origin_matches_host_ignoring_scheme_test() -> Nil {
  same_origin("http://app.example.com", "app.example.com") |> should.be_true

  same_origin("https://app.example.com", "app.example.com") |> should.be_true
}

pub fn same_origin_rejects_cross_origin_test() -> Nil {
  same_origin("https://evil.example.com", "app.example.com") |> should.be_false
}

pub fn same_origin_matches_non_default_port_test() -> Nil {
  same_origin("http://127.0.0.1:8080", "127.0.0.1:8080") |> should.be_true
}

pub fn same_origin_rejects_port_mismatch_test() -> Nil {
  same_origin("http://127.0.0.1:8080", "127.0.0.1:9090") |> should.be_false
}

pub fn same_origin_is_case_insensitive_on_host_test() -> Nil {
  same_origin("https://APP.Example.COM", "app.example.com") |> should.be_true
}

pub fn same_origin_rejects_opaque_origin_test() -> Nil {
  // Sandboxed iframes / file:// documents send `Origin: null`.
  same_origin("null", "app.example.com") |> should.be_false
}

pub fn same_origin_rejects_malformed_origin_test() -> Nil {
  same_origin("garbage", "app.example.com") |> should.be_false

  // Scheme present but no host authority.
  same_origin("https://", "app.example.com") |> should.be_false
}

pub fn same_origin_matches_forwarded_host_authority_test() -> Nil {
  // Behind a reverse proxy that preserves the public Host header, the browser
  // Origin authority (host:port) must match the forwarded Host authority.
  same_origin("https://public.example.com:8443", "public.example.com:8443")
  |> should.be_true
}

pub fn same_origin_without_origin_header_is_admitted_test() -> Nil {
  // Non-browser clients omit `Origin`; they cannot be driven into a
  // cross-site upgrade, so they are admitted.
  origin.allowed(policy: origin.SameOrigin, origin: None, host: None)
  |> should.be_true
}

pub fn same_origin_without_host_header_fails_closed_test() -> Nil {
  origin.allowed(
    policy: origin.SameOrigin,
    origin: Some("https://app.example.com"),
    host: None,
  )
  |> should.be_false
}

pub fn allow_list_requires_exact_match_test() -> Nil {
  let policy = origin.AllowList(["https://app.example.com"])

  origin.allowed(
    policy: policy,
    origin: Some("https://app.example.com"),
    host: None,
  )
  |> should.be_true

  origin.allowed(
    policy: policy,
    origin: Some("https://evil.example.com"),
    host: None,
  )
  |> should.be_false

  // An allow-list requires an explicit match, so a missing header is refused.
  origin.allowed(policy: policy, origin: None, host: None) |> should.be_false
}

pub fn allow_all_admits_everything_test() -> Nil {
  origin.allowed(policy: origin.AllowAll, origin: None, host: None)
  |> should.be_true

  origin.allowed(
    policy: origin.AllowAll,
    origin: Some("https://evil.example.com"),
    host: Some("app.example.com"),
  )
  |> should.be_true
}
