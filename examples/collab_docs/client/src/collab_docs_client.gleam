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

/// Failures when restoring or merging a document from encoded state.
pub type DocumentError {
  /// The encoded state was not valid document JSON.
  InvalidState(reason: json.DecodeError)
  /// The decoded state could not be merged into the local document.
  MergeFailed(reason: crdt.MergeError)
}

pub fn new_document(replica: String) -> Document {
  Document(
    replica: replica,
    state: or_map.new(replica_id.new(replica), crdt.MvRegisterSpec),
  )
}

pub fn from_json(
  replica: String,
  encoded: String,
) -> Result(Document, DocumentError) {
  case or_map.from_json(encoded) {
    Error(reason) -> Error(InvalidState(reason))
    Ok(remote) -> {
      let Document(replica: _, state: local) = new_document(replica)
      case or_map.merge(local, remote) {
        Error(reason) -> Error(MergeFailed(reason))
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
) -> Result(Document, DocumentError) {
  let Document(replica, state) = document
  case or_map.from_json(remote_json) {
    Error(reason) -> Error(InvalidState(reason))
    Ok(remote) ->
      case or_map.merge(state, remote) {
        Error(reason) -> Error(MergeFailed(reason))
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
    // Documents only ever store MV-register blocks; render any other CRDT
    // kind (or a missing key) as an empty block.
    let values = case or_map.get(state, id) {
      Ok(crdt.CrdtMvRegister(register)) ->
        register
        |> mv_register.value
        |> list.sort(by: string.compare)
      Ok(crdt.CrdtGCounter(_))
      | Ok(crdt.CrdtPnCounter(_))
      | Ok(crdt.CrdtLwwRegister(_))
      | Ok(crdt.CrdtGSet(_))
      | Ok(crdt.CrdtTwoPSet(_))
      | Ok(crdt.CrdtOrSet(_))
      | Ok(crdt.CrdtVersionVector(_))
      | Error(Nil) -> []
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
  // Documents only ever store MV-register blocks; leave any other CRDT
  // kind untouched.
  let updated =
    or_map.update(state, id, fn(value) {
      case value {
        crdt.CrdtMvRegister(register) -> {
          let local_register =
            mv_register.new(replica_id)
            |> mv_register.merge(register)
          crdt.CrdtMvRegister(mv_register.set(local_register, block_json))
        }
        crdt.CrdtGCounter(_) as other
        | crdt.CrdtPnCounter(_) as other
        | crdt.CrdtLwwRegister(_) as other
        | crdt.CrdtGSet(_) as other
        | crdt.CrdtTwoPSet(_) as other
        | crdt.CrdtOrSet(_) as other
        | crdt.CrdtVersionVector(_) as other -> other
      }
    })
  Document(replica: replica, state: updated)
}

fn extract_block_id(block_json: String) -> Result(String, Nil) {
  case json.parse(from: block_json, using: decode.at(["id"], decode.string)) {
    Ok("") -> Error(Nil)
    Ok(id) -> Ok(id)
    Error(_) -> Error(Nil)
  }
}
