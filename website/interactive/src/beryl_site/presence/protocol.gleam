import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

pub type JoinError {
  JoinError(code: Int, error: String)
}

/// Decodes a join error JSON string from the Phoenix channel (e.g. 409
/// unsupported compatibility_version).
pub fn decode_join_error(encoded: String) -> Result(JoinError, String) {
  let decoder = {
    use code <- decode.field("code", decode.int)
    use error <- decode.field("error", decode.string)
    decode.success(JoinError(code:, error:))
  }
  json.parse(encoded, decoder)
  |> result.replace_error("invalid_join_error")
}

pub type Meta {
  Meta(name: String, color: String, phx_ref: String)
}

pub type PresenceState =
  Dict(String, List(Meta))

pub type PresenceDiff {
  PresenceDiff(joins: PresenceState, leaves: PresenceState)
}

pub type JoinReply {
  JoinReply(
    compatibility_version: Int,
    client_id: String,
    presence_state: PresenceState,
  )
}

/// Builds a PresenceState from a list of (client_id, metas) pairs.
pub fn state(entries: List(#(String, List(Meta)))) -> PresenceState {
  dict.from_list(entries)
}

fn meta_decoder() -> decode.Decoder(Meta) {
  use name <- decode.field("name", decode.string)
  use color <- decode.field("color", decode.string)
  use phx_ref <- decode.field("phx_ref", decode.string)
  decode.success(Meta(name:, color:, phx_ref:))
}

fn state_decoder() -> decode.Decoder(PresenceState) {
  // Each client entry is {"metas": [...]} — decode dict values by extracting metas.
  decode.dict(decode.string, {
    use metas <- decode.field("metas", decode.list(meta_decoder()))
    decode.success(metas)
  })
}

/// Decodes a join reply JSON string from the Phoenix channel.
pub fn decode_join(encoded: String) -> Result(JoinReply, String) {
  let decoder = {
    use compatibility_version <- decode.field(
      "compatibility_version",
      decode.int,
    )
    use client_id <- decode.field("client_id", decode.string)
    use presence_state <- decode.field("presence_state", state_decoder())
    decode.success(JoinReply(
      compatibility_version:,
      client_id:,
      presence_state:,
    ))
  }

  json.parse(encoded, decoder)
  |> result.replace_error("invalid_join_reply")
}

/// Decodes a presence_diff JSON string from the Phoenix channel.
pub fn decode_diff(encoded: String) -> Result(PresenceDiff, String) {
  let decoder = {
    use joins <- decode.field("joins", state_decoder())
    use leaves <- decode.field("leaves", state_decoder())
    decode.success(PresenceDiff(joins:, leaves:))
  }

  json.parse(encoded, decoder)
  |> result.replace_error("invalid_presence_diff")
}

/// Applies a presence diff to the current state, merging joins and removing
/// leaves by phx_ref.
pub fn apply_diff(state: PresenceState, diff: PresenceDiff) -> PresenceState {
  let with_joins =
    diff.joins
    |> dict.to_list
    |> list.fold(state, fn(current, entry) {
      let #(key, joined) = entry
      let existing = dict.get(current, key) |> result.unwrap([])
      dict.insert(current, key, append_unique_refs(existing, joined))
    })

  diff.leaves
  |> dict.to_list
  |> list.fold(with_joins, fn(current, entry) {
    let #(key, left) = entry
    let leaving_refs = list.map(left, fn(meta) { meta.phx_ref })
    let remaining =
      dict.get(current, key)
      |> result.unwrap([])
      |> list.filter(fn(meta) { !list.contains(leaving_refs, meta.phx_ref) })

    case remaining {
      [] -> dict.delete(current, key)
      _ -> dict.insert(current, key, remaining)
    }
  })
}

fn append_unique_refs(existing: List(Meta), joined: List(Meta)) -> List(Meta) {
  list.fold(joined, existing, fn(current, meta) {
    case list.any(current, fn(item) { item.phx_ref == meta.phx_ref }) {
      True -> current
      False -> list.append(current, [meta])
    }
  })
}
