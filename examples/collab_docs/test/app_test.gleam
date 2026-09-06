//// Contract tests for the embeddable `collab_document/app` logic (the app-side
//// dispatch document handler): document-key encoding and join-level
//// tenant-token authorization.

import collab_document/app
import collab_document/auth
import collab_document/document_store
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleeunit/should

fn json_to_payload(raw: String) -> dynamic.Dynamic {
  let assert Ok(value) = json.parse(from: raw, using: decode.dynamic)
  value
}

pub fn document_key_uses_json_array_encoding_test() -> Nil {
  app.build_document_key("tenant", "document")
  |> should.equal("[\"tenant\",\"document\"]")
}

pub fn document_key_distinguishes_slashes_in_wildcards_test() -> Nil {
  app.build_document_key("a/b", "c")
  |> should.not_equal(app.build_document_key("a", "b/c"))
}

pub fn join_with_valid_tenant_token_is_accepted_test() -> Nil {
  let assert Ok(store) = document_store.start()
  let secret = auth.new_secret()
  let token = auth.sign_tenant("demo", secret)
  let context = app.Context(store: store, secret: secret)

  let payload = json_to_payload("{\"token\":\"" <> token <> "\"}")
  let _ = app.authorize_join(context, ["demo:readme"], payload) |> should.be_ok
  Nil
}

pub fn join_without_token_is_rejected_test() -> Nil {
  let assert Ok(store) = document_store.start()
  let secret = auth.new_secret()
  let context = app.Context(store: store, secret: secret)

  let _ =
    app.authorize_join(context, ["demo:readme"], json_to_payload("{}"))
    |> should.be_error
  Nil
}

pub fn join_with_token_for_other_tenant_is_rejected_test() -> Nil {
  let assert Ok(store) = document_store.start()
  let secret = auth.new_secret()
  // A token signed for a different tenant must not authorize this document.
  let token = auth.sign_tenant("someone-else", secret)
  let context = app.Context(store: store, secret: secret)

  let payload = json_to_payload("{\"token\":\"" <> token <> "\"}")
  let _ =
    app.authorize_join(context, ["demo:readme"], payload) |> should.be_error
  Nil
}
