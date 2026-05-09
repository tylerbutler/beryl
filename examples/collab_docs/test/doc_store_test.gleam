import collab_docs/doc_store
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import lattice_core/replica_id
import lattice_maps/crdt
import lattice_maps/or_map.{type ORMap}
import lattice_registers/mv_register

const doc_key = "demo/welcome"

pub fn put_and_get_state_test() {
  let assert Ok(store) = doc_store.start()
  let original = or_map.new(replica_id.new("server"), crdt.MvRegisterSpec)

  doc_store.merge_state(store, doc_key, encode(original))

  let assert Ok(encoded) = doc_store.get_state(store, doc_key)
  let assert Ok(restored) = or_map.from_json(encoded)
  or_map.keys(restored)
  |> should.equal([])
}

pub fn missing_state_returns_error_test() {
  let assert Ok(store) = doc_store.start()

  doc_store.get_state(store, "missing")
  |> should.equal(Error(Nil))
}

pub fn invalid_json_merge_does_not_create_state_test() {
  let assert Ok(store) = doc_store.start()

  doc_store.merge_state(store, doc_key, "not json")

  doc_store.get_state(store, doc_key)
  |> should.equal(Error(Nil))
}

pub fn valid_states_for_same_key_merge_blocks_test() {
  let assert Ok(store) = doc_store.start()
  let a = new_doc("a") |> put_block("a", "{\"id\":\"a\",\"text\":\"A\"}")
  let b = new_doc("b") |> put_block("b", "{\"id\":\"b\",\"text\":\"B\"}")

  doc_store.merge_state(store, doc_key, encode(a))
  doc_store.merge_state(store, doc_key, encode(b))

  let assert Ok(encoded) = doc_store.get_state(store, doc_key)
  let assert Ok(merged) = or_map.from_json(encoded)
  sorted_keys(merged)
  |> should.equal(["a", "b"])
  block_values(merged, "a")
  |> should.equal(["{\"id\":\"a\",\"text\":\"A\"}"])
  block_values(merged, "b")
  |> should.equal(["{\"id\":\"b\",\"text\":\"B\"}"])
}

pub fn type_mismatch_keeps_cached_state_test() {
  let assert Ok(store) = doc_store.start()
  let local = new_doc("a") |> put_block("a", "{\"id\":\"a\",\"text\":\"A\"}")
  let mismatched = or_map.new(replica_id.new("counter"), crdt.GCounterSpec)

  doc_store.merge_state(store, doc_key, encode(local))
  doc_store.merge_state(store, doc_key, encode(mismatched))

  let assert Ok(encoded) = doc_store.get_state(store, doc_key)
  let assert Ok(restored) = or_map.from_json(encoded)
  sorted_keys(restored)
  |> should.equal(["a"])
}

fn new_doc(replica: String) -> ORMap {
  or_map.new(replica_id.new(replica), crdt.MvRegisterSpec)
}

fn put_block(map: ORMap, id: String, block_json: String) -> ORMap {
  or_map.update(map, id, fn(value) {
    case value {
      crdt.CrdtMvRegister(register) ->
        register
        |> mv_register.set(block_json)
        |> crdt.CrdtMvRegister
      other -> other
    }
  })
}

fn encode(map: ORMap) -> String {
  map
  |> or_map.to_json
  |> json.to_string
}

fn sorted_keys(map: ORMap) -> List(String) {
  map
  |> or_map.keys
  |> list.sort(by: string.compare)
}

fn block_values(map: ORMap, id: String) -> List(String) {
  case or_map.get(map, id) {
    Ok(crdt.CrdtMvRegister(register)) ->
      register
      |> mv_register.value
      |> list.sort(by: string.compare)
    _ -> []
  }
}
