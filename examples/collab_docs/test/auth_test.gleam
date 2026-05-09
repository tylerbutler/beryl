import collab_docs/auth
import gleeunit/should

pub fn signed_token_round_trips_test() {
  let secret = auth.new_secret()
  let token = auth.sign_tenant("demo", secret)

  auth.verify_tenant(token, "demo", secret)
  |> should.equal(Ok(Nil))
}

pub fn token_for_other_tenant_is_rejected_test() {
  let secret = auth.new_secret()
  let token = auth.sign_tenant("alice", secret)

  auth.verify_tenant(token, "bob", secret)
  |> should.equal(Error(Nil))
}

pub fn token_signed_with_other_secret_is_rejected_test() {
  let secret_a = auth.new_secret()
  let secret_b = auth.new_secret()
  let token = auth.sign_tenant("demo", secret_a)

  auth.verify_tenant(token, "demo", secret_b)
  |> should.equal(Error(Nil))
}

pub fn malformed_token_is_rejected_test() {
  let secret = auth.new_secret()

  auth.verify_tenant("not.a.real.token", "demo", secret)
  |> should.equal(Error(Nil))
}

pub fn empty_token_is_rejected_test() {
  let secret = auth.new_secret()

  auth.verify_tenant("", "demo", secret)
  |> should.equal(Error(Nil))
}
