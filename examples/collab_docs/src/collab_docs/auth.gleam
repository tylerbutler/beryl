//// Tenant-scoped bearer token auth for collab_docs.
////
//// Tokens are HMAC-signed strings produced via `gleam/crypto.sign_message`
//// and bound to a tenant identifier. The server signs a token for each
//// tenant the user is allowed to access (here, just `"demo"`) and embeds
//// it in the page HTML. The client passes the token in the Phoenix join
//// payload, and the channel handler verifies it before allowing the join.
////
//// This is a minimal demo of channel-level auth — production code would
//// add an expiry claim, scope tokens to a user/session, and load the
//// secret from a secret manager rather than generating it at boot.

import gleam/bit_array
import gleam/crypto

/// Generate a fresh shared secret at server startup. Tokens issued under
/// this secret become invalid on every restart, which is intentional for
/// a demo.
pub fn new_secret() -> BitArray {
  crypto.strong_random_bytes(32)
}

/// Sign a tenant identifier with the shared secret. The returned token
/// can be safely embedded in HTML or sent over the wire — it carries
/// the tenant in clear text plus an HMAC the client cannot forge.
pub fn sign_tenant(tenant: String, secret: BitArray) -> String {
  crypto.sign_message(bit_array.from_string(tenant), secret, crypto.Sha256)
}

/// Verify that `token` was issued for `expected_tenant` under `secret`.
///
/// Returns `Ok(Nil)` when the token is well-formed, the signature checks
/// out, and the tenant inside the token matches `expected_tenant`.
/// Returns `Error(Nil)` for any failure mode (tampering, wrong tenant,
/// malformed token).
pub fn verify_tenant(
  token: String,
  expected_tenant: String,
  secret: BitArray,
) -> Result(Nil, Nil) {
  case crypto.verify_signed_message(token, secret) {
    Error(Nil) -> Error(Nil)
    Ok(claimed_bits) ->
      case bit_array.to_string(claimed_bits) {
        Error(Nil) -> Error(Nil)
        Ok(claimed_tenant) ->
          // Constant-time string compare via the underlying bit-arrays so
          // tenant-name length isn't leaked through timing.
          case
            crypto.secure_compare(
              bit_array.from_string(claimed_tenant),
              bit_array.from_string(expected_tenant),
            )
          {
            True -> Ok(Nil)
            False -> Error(Nil)
          }
      }
  }
}
