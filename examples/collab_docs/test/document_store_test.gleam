import collab_document/document_store
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import lattice_core/replica_id
import lattice_maps/crdt
import lattice_maps/or_map.{type ORMap}
import lattice_registers/mv_register

const document_key = "demo/welcome"

pub fn put_and_get_state_test() -> Nil {
  let assert Ok(store) = document_store.start()
  let original = or_map.new(replica_id.new("server"), crdt.MvRegisterSpec)

  document_store.merge_state(store, document_key, encode(original))

  let assert Ok(encoded) = document_store.get_state(store, document_key)
  let assert Ok(restored) = or_map.from_json(encoded)
  or_map.keys(restored)
  |> should.equal([])
}

pub fn missing_state_returns_error_test() -> Nil {
  let assert Ok(store) = document_store.start()

  document_store.get_state(store, "missing")
  |> should.equal(Error(document_store.NotFound))
}

pub fn invalid_json_merge_does_not_create_state_test() -> Nil {
  let assert Ok(store) = document_store.start()

  document_store.merge_state(store, document_key, "not json")

  document_store.get_state(store, document_key)
  |> should.equal(Error(document_store.NotFound))
}

pub fn valid_states_for_same_key_merge_blocks_test() -> Nil {
  let assert Ok(store) = document_store.start()
  let a = new_document("a") |> put_block("a", "{\"id\":\"a\",\"text\":\"A\"}")
  let b = new_document("b") |> put_block("b", "{\"id\":\"b\",\"text\":\"B\"}")

  document_store.merge_state(store, document_key, encode(a))
  document_store.merge_state(store, document_key, encode(b))

  let assert Ok(encoded) = document_store.get_state(store, document_key)
  let assert Ok(merged) = or_map.from_json(encoded)
  sorted_keys(merged)
  |> should.equal(["a", "b"])
  block_values(merged, "a")
  |> should.equal(["{\"id\":\"a\",\"text\":\"A\"}"])
  block_values(merged, "b")
  |> should.equal(["{\"id\":\"b\",\"text\":\"B\"}"])
}

pub fn type_mismatch_keeps_cached_state_test() -> Nil {
  let assert Ok(store) = document_store.start()
  let local =
    new_document("a") |> put_block("a", "{\"id\":\"a\",\"text\":\"A\"}")
  let mismatched = or_map.new(replica_id.new("counter"), crdt.GCounterSpec)

  document_store.merge_state(store, document_key, encode(local))
  document_store.merge_state(store, document_key, encode(mismatched))

  let assert Ok(encoded) = document_store.get_state(store, document_key)
  let assert Ok(restored) = or_map.from_json(encoded)
  sorted_keys(restored)
  |> should.equal(["a"])
}

fn new_document(replica: String) -> ORMap {
  or_map.new(replica_id.new(replica), crdt.MvRegisterSpec)
}

fn put_block(map: ORMap, id: String, block_json: String) -> ORMap {
  or_map.update(map, id, fn(value) {
    case value {
      crdt.CrdtMvRegister(register) ->
        register
        |> mv_register.set(block_json)
        |> crdt.CrdtMvRegister
      crdt.CrdtGCounter(counter) -> crdt.CrdtGCounter(counter)
      crdt.CrdtGSet(set) -> crdt.CrdtGSet(set)
      crdt.CrdtLwwRegister(register) -> crdt.CrdtLwwRegister(register)
      crdt.CrdtPnCounter(counter) -> crdt.CrdtPnCounter(counter)
      crdt.CrdtOrSet(set) -> crdt.CrdtOrSet(set)
      crdt.CrdtTwoPSet(set) -> crdt.CrdtTwoPSet(set)
      crdt.CrdtVersionVector(vector) -> crdt.CrdtVersionVector(vector)
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
    Error(_)
    | Ok(crdt.CrdtGCounter(_))
    | Ok(crdt.CrdtGSet(_))
    | Ok(crdt.CrdtLwwRegister(_))
    | Ok(crdt.CrdtPnCounter(_))
    | Ok(crdt.CrdtOrSet(_))
    | Ok(crdt.CrdtTwoPSet(_))
    | Ok(crdt.CrdtVersionVector(_)) -> []
  }
}
