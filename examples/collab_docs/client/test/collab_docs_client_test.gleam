import collab_docs_client as client
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

fn add_block(document: client.Document, encoded: String) -> client.Document {
  let assert Ok(updated) = client.add_block(document, encoded)
  updated
}

fn edit_block(
  document: client.Document,
  expected_id: String,
  encoded: String,
) -> client.Document {
  let assert Ok(updated) = client.edit_block(document, expected_id, encoded)
  updated
}

pub fn independent_adds_converge_test() -> Nil {
  let a =
    client.new_document("a")
    |> add_block("{\"id\":\"a\",\"text\":\"A\"}")
  let b =
    client.new_document("b")
    |> add_block("{\"id\":\"b\",\"text\":\"B\"}")

  let a_merged = client.merge_json_or_keep(a, client.document_to_json(b))
  let b_merged = client.merge_json_or_keep(b, client.document_to_json(a))

  client.blocks(a_merged)
  |> should.equal([
    client.RenderBlock("a", ["{\"id\":\"a\",\"text\":\"A\"}"]),
    client.RenderBlock("b", ["{\"id\":\"b\",\"text\":\"B\"}"]),
  ])
  client.blocks(b_merged)
  |> should.equal(client.blocks(a_merged))
}

pub fn concurrent_edits_create_conflict_test() -> Nil {
  let initial = "{\"id\":\"shared\",\"text\":\"initial\"}"
  let a_base =
    client.new_document("a")
    |> add_block(initial)
    |> client.merge_json_or_keep(
      client.new_document("b")
      |> add_block(initial)
      |> client.document_to_json,
    )
  let b_base =
    client.new_document("b")
    |> add_block(initial)
    |> client.merge_json_or_keep(client.document_to_json(a_base))

  let a =
    edit_block(a_base, "shared", "{\"id\":\"shared\",\"text\":\"from a\"}")
  let b =
    edit_block(b_base, "shared", "{\"id\":\"shared\",\"text\":\"from b\"}")

  client.merge_json_or_keep(a, client.document_to_json(b))
  |> client.blocks
  |> should.equal([
    client.RenderBlock("shared", [
      "{\"id\":\"shared\",\"text\":\"from a\"}",
      "{\"id\":\"shared\",\"text\":\"from b\"}",
    ]),
  ])
}

pub fn duplicate_merge_is_idempotent_test() -> Nil {
  let remote =
    client.new_document("b")
    |> add_block("{\"id\":\"only\",\"text\":\"one\"}")
    |> client.document_to_json

  let merged_once = client.merge_json_or_keep(client.new_document("a"), remote)
  let merged_twice = client.merge_json_or_keep(merged_once, remote)

  client.blocks(merged_twice)
  |> should.equal([
    client.RenderBlock("only", ["{\"id\":\"only\",\"text\":\"one\"}"]),
  ])
}

pub fn invalid_block_json_in_add_is_rejected_test() -> Nil {
  let _ =
    client.new_document("a")
    |> client.add_block("not json")
    |> should.be_error
  Nil
}

pub fn empty_block_id_in_add_is_rejected_test() -> Nil {
  client.new_document("a")
  |> client.add_block("{\"id\":\"\",\"text\":\"ignored\"}")
  |> should.equal(Error(client.EmptyBlockId))
}

pub fn edit_block_with_mismatched_id_is_rejected_test() -> Nil {
  let document =
    client.new_document("a")
    |> add_block("{\"id\":\"one\",\"text\":\"original\"}")

  document
  |> client.edit_block("one", "{\"id\":\"two\",\"text\":\"ignored\"}")
  |> should.equal(Error(client.BlockIdMismatch(expected: "one", actual: "two")))
  client.blocks(document)
  |> should.equal([
    client.RenderBlock("one", ["{\"id\":\"one\",\"text\":\"original\"}"]),
  ])
}

pub fn merge_json_returns_invalid_state_for_invalid_json_test() -> Nil {
  let _ =
    client.new_document("a")
    |> client.merge_json("not json")
    |> should.be_error
  Nil
}

pub fn remove_block_removes_existing_block_test() -> Nil {
  client.new_document("a")
  |> add_block("{\"id\":\"one\",\"text\":\"One\"}")
  |> add_block("{\"id\":\"two\",\"text\":\"Two\"}")
  |> client.remove_block("one")
  |> client.blocks
  |> should.equal([
    client.RenderBlock("two", ["{\"id\":\"two\",\"text\":\"Two\"}"]),
  ])
}

pub fn json_to_document_restores_state_with_requested_replica_test() -> Nil {
  let original =
    client.new_document("a")
    |> add_block("{\"id\":\"alpha\",\"text\":\"Alpha\"}")

  let assert Ok(restored) =
    client.json_to_document("b", client.document_to_json(original))

  let updated =
    restored
    |> edit_block("alpha", "{\"id\":\"alpha\",\"text\":\"Beta\"}")
    |> add_block("{\"id\":\"gamma\",\"text\":\"Gamma\"}")

  original
  |> client.merge_json_or_keep(client.document_to_json(updated))
  |> client.blocks
  |> should.equal([
    client.RenderBlock("alpha", ["{\"id\":\"alpha\",\"text\":\"Beta\"}"]),
    client.RenderBlock("gamma", ["{\"id\":\"gamma\",\"text\":\"Gamma\"}"]),
  ])
}

pub fn json_to_document_returns_invalid_state_for_invalid_json_test() -> Nil {
  let _ =
    client.json_to_document("a", "not json")
    |> should.be_error
  Nil
}

pub fn blocks_json_renders_sorted_blocks_test() -> Nil {
  client.new_document("a")
  |> add_block("{\"id\":\"b\",\"text\":\"B\"}")
  |> add_block("{\"id\":\"a\",\"text\":\"A\"}")
  |> client.blocks_json
  |> should.equal(
    "[{\"id\":\"a\",\"values\":[\"{\\\"id\\\":\\\"a\\\",\\\"text\\\":\\\"A\\\"}\"]},{\"id\":\"b\",\"values\":[\"{\\\"id\\\":\\\"b\\\",\\\"text\\\":\\\"B\\\"}\"]}]",
  )
}

pub fn concurrent_add_survives_remove_test() -> Nil {
  let a =
    client.new_document("a")
    |> add_block("{\"id\":\"shared\",\"text\":\"from a\"}")

  let b =
    client.new_document("b")
    |> add_block("{\"id\":\"shared\",\"text\":\"from b\"}")

  a
  |> client.remove_block("shared")
  |> client.merge_json_or_keep(client.document_to_json(b))
  |> client.blocks
  |> should.equal([
    client.RenderBlock("shared", [
      "{\"id\":\"shared\",\"text\":\"from a\"}",
      "{\"id\":\"shared\",\"text\":\"from b\"}",
    ]),
  ])
}

pub fn remove_and_concurrent_edit_converge_to_edit_test() -> Nil {
  let initial = "{\"id\":\"shared\",\"text\":\"initial\"}"
  let a_base =
    client.new_document("a")
    |> add_block(initial)

  let b_base =
    client.new_document("b")
    |> client.merge_json_or_keep(client.document_to_json(a_base))

  a_base
  |> client.remove_block("shared")
  |> client.merge_json_or_keep(
    b_base
    |> edit_block("shared", "{\"id\":\"shared\",\"text\":\"edited\"}")
    |> client.document_to_json,
  )
  |> client.blocks
  |> should.equal([
    client.RenderBlock("shared", ["{\"id\":\"shared\",\"text\":\"edited\"}"]),
  ])
}
