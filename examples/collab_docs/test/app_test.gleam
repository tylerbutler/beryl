import collab_docs/app
import gleeunit/should

pub fn document_key_uses_json_array_encoding_test() {
  app.build_document_key("tenant", "document")
  |> should.equal("[\"tenant\",\"document\"]")
}

pub fn document_key_distinguishes_slashes_in_wildcards_test() {
  app.build_document_key("a/b", "c")
  |> should.not_equal(app.build_document_key("a", "b/c"))
}
