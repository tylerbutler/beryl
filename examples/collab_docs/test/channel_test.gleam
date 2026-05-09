import collab_docs/channel
import gleeunit/should

pub fn document_key_uses_json_array_encoding_test() {
  channel.document_key("tenant", "document")
  |> should.equal("[\"tenant\",\"document\"]")
}

pub fn document_key_distinguishes_slashes_in_wildcards_test() {
  channel.document_key("a/b", "c")
  |> should.not_equal(channel.document_key("a", "b/c"))
}
