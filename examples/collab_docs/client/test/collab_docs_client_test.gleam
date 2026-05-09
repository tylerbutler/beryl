import collab_docs_client as client
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn independent_adds_converge_test() {
  let a =
    client.new_document("a")
    |> client.add_block("{\"id\":\"a\",\"text\":\"A\"}")
  let b =
    client.new_document("b")
    |> client.add_block("{\"id\":\"b\",\"text\":\"B\"}")

  let a_merged = client.merge_json_or_keep(a, client.to_json(b))
  let b_merged = client.merge_json_or_keep(b, client.to_json(a))

  client.blocks(a_merged)
  |> should.equal([
    client.RenderBlock("a", ["{\"id\":\"a\",\"text\":\"A\"}"]),
    client.RenderBlock("b", ["{\"id\":\"b\",\"text\":\"B\"}"]),
  ])
  client.blocks(b_merged)
  |> should.equal(client.blocks(a_merged))
}

pub fn concurrent_edits_create_conflict_test() {
  let initial = "{\"id\":\"shared\",\"text\":\"initial\"}"
  let a_base =
    client.new_document("a")
    |> client.add_block(initial)
    |> client.merge_json_or_keep(
      client.new_document("b")
      |> client.add_block(initial)
      |> client.to_json,
    )
  let b_base =
    client.new_document("b")
    |> client.add_block(initial)
    |> client.merge_json_or_keep(client.to_json(a_base))

  let a =
    client.edit_block(
      a_base,
      "shared",
      "{\"id\":\"shared\",\"text\":\"from a\"}",
    )
  let b =
    client.edit_block(
      b_base,
      "shared",
      "{\"id\":\"shared\",\"text\":\"from b\"}",
    )

  client.merge_json_or_keep(a, client.to_json(b))
  |> client.blocks
  |> should.equal([
    client.RenderBlock("shared", [
      "{\"id\":\"shared\",\"text\":\"from a\"}",
      "{\"id\":\"shared\",\"text\":\"from b\"}",
    ]),
  ])
}

pub fn duplicate_merge_is_idempotent_test() {
  let remote =
    client.new_document("b")
    |> client.add_block("{\"id\":\"only\",\"text\":\"one\"}")
    |> client.to_json

  let merged_once = client.merge_json_or_keep(client.new_document("a"), remote)
  let merged_twice = client.merge_json_or_keep(merged_once, remote)

  client.blocks(merged_twice)
  |> should.equal([
    client.RenderBlock("only", ["{\"id\":\"only\",\"text\":\"one\"}"]),
  ])
}

pub fn invalid_block_json_in_add_is_ignored_test() {
  client.new_document("a")
  |> client.add_block("not json")
  |> client.blocks
  |> should.equal([])
}

pub fn edit_block_with_mismatched_id_is_ignored_test() {
  let document =
    client.new_document("a")
    |> client.add_block("{\"id\":\"one\",\"text\":\"original\"}")

  document
  |> client.edit_block("one", "{\"id\":\"two\",\"text\":\"ignored\"}")
  |> client.blocks
  |> should.equal(client.blocks(document))
}

pub fn merge_json_returns_invalid_state_for_invalid_json_test() {
  client.new_document("a")
  |> client.merge_json("not json")
  |> should.equal(Error("invalid_state"))
}

pub fn remove_block_removes_existing_block_test() {
  client.new_document("a")
  |> client.add_block("{\"id\":\"one\",\"text\":\"One\"}")
  |> client.add_block("{\"id\":\"two\",\"text\":\"Two\"}")
  |> client.remove_block("one")
  |> client.blocks
  |> should.equal([
    client.RenderBlock("two", ["{\"id\":\"two\",\"text\":\"Two\"}"]),
  ])
}

pub fn from_json_restores_state_with_requested_replica_test() {
  let original =
    client.new_document("a")
    |> client.add_block("{\"id\":\"alpha\",\"text\":\"Alpha\"}")

  let assert Ok(restored) = client.from_json("b", client.to_json(original))

  let updated =
    restored
    |> client.edit_block("alpha", "{\"id\":\"alpha\",\"text\":\"Beta\"}")
    |> client.add_block("{\"id\":\"gamma\",\"text\":\"Gamma\"}")

  original
  |> client.merge_json_or_keep(client.to_json(updated))
  |> client.blocks
  |> should.equal([
    client.RenderBlock("alpha", ["{\"id\":\"alpha\",\"text\":\"Beta\"}"]),
    client.RenderBlock("gamma", ["{\"id\":\"gamma\",\"text\":\"Gamma\"}"]),
  ])
}

pub fn from_json_returns_invalid_state_for_invalid_json_test() {
  client.from_json("a", "not json")
  |> should.equal(Error("invalid_state"))
}

pub fn blocks_json_renders_sorted_blocks_test() {
  client.new_document("a")
  |> client.add_block("{\"id\":\"b\",\"text\":\"B\"}")
  |> client.add_block("{\"id\":\"a\",\"text\":\"A\"}")
  |> client.blocks_json
  |> should.equal(
    "[{\"id\":\"a\",\"values\":[\"{\\\"id\\\":\\\"a\\\",\\\"text\\\":\\\"A\\\"}\"]},{\"id\":\"b\",\"values\":[\"{\\\"id\\\":\\\"b\\\",\\\"text\\\":\\\"B\\\"}\"]}]",
  )
}

pub fn concurrent_add_survives_remove_test() {
  let a =
    client.new_document("a")
    |> client.add_block("{\"id\":\"shared\",\"text\":\"from a\"}")

  let b =
    client.new_document("b")
    |> client.add_block("{\"id\":\"shared\",\"text\":\"from b\"}")

  a
  |> client.remove_block("shared")
  |> client.merge_json_or_keep(client.to_json(b))
  |> client.blocks
  |> should.equal([
    client.RenderBlock("shared", [
      "{\"id\":\"shared\",\"text\":\"from a\"}",
      "{\"id\":\"shared\",\"text\":\"from b\"}",
    ]),
  ])
}

pub fn remove_and_concurrent_edit_converge_to_edit_test() {
  let initial = "{\"id\":\"shared\",\"text\":\"initial\"}"
  let a_base =
    client.new_document("a")
    |> client.add_block(initial)

  let b_base =
    client.new_document("b")
    |> client.merge_json_or_keep(client.to_json(a_base))

  a_base
  |> client.remove_block("shared")
  |> client.merge_json_or_keep(
    b_base
    |> client.edit_block("shared", "{\"id\":\"shared\",\"text\":\"edited\"}")
    |> client.to_json,
  )
  |> client.blocks
  |> should.equal([
    client.RenderBlock("shared", ["{\"id\":\"shared\",\"text\":\"edited\"}"]),
  ])
}
