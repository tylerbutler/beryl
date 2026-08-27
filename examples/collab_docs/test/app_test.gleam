//// Contract tests for the embeddable `collab_docs/app` logic (the app-side
//// dispatch document handler): document-key encoding and join-level
//// tenant-token authorization.

import collab_docs/app
import collab_docs/auth
import collab_docs/doc_store
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleeunit/should

fn payload_from_json(raw: String) -> dynamic.Dynamic {
  let assert Ok(value) = json.parse(from: raw, using: decode.dynamic)
  value
}

pub fn document_key_uses_json_array_encoding_test() {
  app.build_document_key("tenant", "document")
  |> should.equal("[\"tenant\",\"document\"]")
}

pub fn document_key_distinguishes_slashes_in_wildcards_test() {
  app.build_document_key("a/b", "c")
  |> should.not_equal(app.build_document_key("a", "b/c"))
}

pub fn join_with_valid_tenant_token_is_accepted_test() {
  let assert Ok(store) = doc_store.start()
  let secret = auth.new_secret()
  let token = auth.sign_tenant("demo", secret)
  let ctx = app.Ctx(store: store, secret: secret)

  let payload = payload_from_json("{\"token\":\"" <> token <> "\"}")
  app.authorize_join(ctx, ["demo:readme"], payload) |> should.be_ok
}

pub fn join_without_token_is_rejected_test() {
  let assert Ok(store) = doc_store.start()
  let secret = auth.new_secret()
  let ctx = app.Ctx(store: store, secret: secret)

  app.authorize_join(ctx, ["demo:readme"], payload_from_json("{}"))
  |> should.be_error
}

pub fn join_with_token_for_other_tenant_is_rejected_test() {
  let assert Ok(store) = doc_store.start()
  let secret = auth.new_secret()
  // A token signed for a different tenant must not authorize this document.
  let token = auth.sign_tenant("someone-else", secret)
  let ctx = app.Ctx(store: store, secret: secret)

  let payload = payload_from_json("{\"token\":\"" <> token <> "\"}")
  app.authorize_join(ctx, ["demo:readme"], payload) |> should.be_error
}
