import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import lattice_core/replica_id
import lattice_maps/crdt
import lattice_maps/or_map.{type ORMap}
import lattice_registers/mv_register

pub opaque type Document {
  Document(replica: String, state: ORMap)
}

pub type RenderBlock {
  RenderBlock(id: String, values: List(String))
}

pub fn main() {
  Nil
}

pub fn new_document(replica: String) -> Document {
  Document(
    replica: replica,
    state: or_map.new(replica_id.new(replica), crdt.MvRegisterSpec),
  )
}

pub fn from_json(replica: String, encoded: String) -> Result(Document, String) {
  case or_map.from_json(encoded) {
    Error(_) -> Error("invalid_state")
    Ok(remote) -> {
      let Document(replica: _, state: local) = new_document(replica)
      case or_map.merge(local, remote) {
        Error(_) -> Error("merge_failed")
        Ok(state) -> Ok(Document(replica: replica, state: state))
      }
    }
  }
}

pub fn to_json(document: Document) -> String {
  let Document(_, state) = document
  state
  |> or_map.to_json
  |> json.to_string
}

pub fn add_block(document: Document, block_json: String) -> Document {
  case extract_block_id(block_json) {
    Error(_) -> document
    Ok(id) -> put_block(document, id, block_json)
  }
}

pub fn edit_block(
  document: Document,
  expected_id: String,
  block_json: String,
) -> Document {
  case extract_block_id(block_json) {
    Ok(actual_id) if actual_id == expected_id ->
      put_block(document, expected_id, block_json)
    _ -> document
  }
}

pub fn remove_block(document: Document, block_id: String) -> Document {
  let Document(replica, state) = document
  Document(replica: replica, state: or_map.remove(state, block_id))
}

pub fn merge_json(
  document: Document,
  remote_json: String,
) -> Result(Document, String) {
  let Document(replica, state) = document
  case or_map.from_json(remote_json) {
    Error(_) -> Error("invalid_state")
    Ok(remote) ->
      case or_map.merge(state, remote) {
        Error(_) -> Error("merge_failed")
        Ok(merged) -> Ok(Document(replica: replica, state: merged))
      }
  }
}

pub fn blocks(document: Document) -> List(RenderBlock) {
  let Document(_, state) = document
  state
  |> or_map.keys
  |> list.sort(by: string.compare)
  |> list.map(fn(id) {
    let values = case or_map.get(state, id) {
      Ok(crdt.CrdtMvRegister(register)) ->
        register
        |> mv_register.value
        |> list.sort(by: string.compare)
      _ -> []
    }
    RenderBlock(id: id, values: values)
  })
}

pub fn blocks_json(document: Document) -> String {
  document
  |> blocks
  |> json.array(of: fn(block) {
    json.object([
      #("id", json.string(block.id)),
      #("values", json.array(block.values, of: json.string)),
    ])
  })
  |> json.to_string
}

pub fn merge_json_or_keep(document: Document, remote_json: String) -> Document {
  case merge_json(document, remote_json) {
    Ok(merged) -> merged
    Error(_) -> document
  }
}

fn put_block(document: Document, id: String, block_json: String) -> Document {
  let Document(replica, state) = document
  let replica_id = replica_id.new(replica)
  let updated =
    or_map.update(state, id, fn(value) {
      case value {
        crdt.CrdtMvRegister(register) -> {
          let local_register =
            mv_register.new(replica_id)
            |> mv_register.merge(register)
          crdt.CrdtMvRegister(mv_register.set(local_register, block_json))
        }
        other -> other
      }
    })
  Document(replica: replica, state: updated)
}

fn extract_block_id(block_json: String) -> Result(String, Nil) {
  case json.parse(from: block_json, using: decode.at(["id"], decode.string)) {
    Ok(id) -> Ok(id)
    Error(_) -> Error(Nil)
  }
}
