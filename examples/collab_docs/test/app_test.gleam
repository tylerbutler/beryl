//// Contract tests for the embeddable `collab_docs/app` logic (the app-side
//// dispatch document handler): document-key encoding and join-level
//// tenant-token authorization.

import beryl/socket
import collab_docs/app
import collab_docs/auth
import collab_docs/doc_store
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleeunit/should

fn document_ref() -> socket.Ref {
  socket.make_join_ref(
    topic: "document:demo:readme",
    join_ref: Some("jr"),
    msg_ref: Some("r"),
  )
}

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
  let context = app.Context(store: store, secret: secret)

  let payload = payload_from_json("{\"token\":\"" <> token <> "\"}")
  let #(model, effects) =
    app.join(context, "s1", "document:demo:readme", payload, document_ref())

  model |> should.be_some
  case effects {
    [socket.AcceptJoin(_, _)] -> Nil
    _ -> should.fail()
  }
}

pub fn join_without_token_is_rejected_test() {
  let assert Ok(store) = doc_store.start()
  let secret = auth.new_secret()
  let context = app.Context(store: store, secret: secret)

  let #(model, effects) =
    app.join(
      context,
      "s1",
      "document:demo:readme",
      payload_from_json("{}"),
      document_ref(),
    )

  model |> should.be_none
  case effects {
    [socket.RejectJoin(_, _)] -> Nil
    _ -> should.fail()
  }
}

pub fn join_with_token_for_other_tenant_is_rejected_test() {
  let assert Ok(store) = doc_store.start()
  let secret = auth.new_secret()
  // A token signed for a different tenant must not authorize this document.
  let token = auth.sign_tenant("someone-else", secret)
  let context = app.Context(store: store, secret: secret)

  let payload = payload_from_json("{\"token\":\"" <> token <> "\"}")
  let #(model, effects) =
    app.join(context, "s1", "document:demo:readme", payload, document_ref())

  model |> should.be_none
  case effects {
    [socket.RejectJoin(_, _)] -> Nil
    _ -> should.fail()
  }
}
