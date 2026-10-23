import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/order
import gleam/result
import gleam/string

pub type PresentUser {
  PresentUser(id: String, name: String, avatar_url: String)
}

type Meta {
  Meta(name: String, avatar_url: String, phx_ref: String)
}

pub opaque type Presence {
  Presence(entries: Dict(String, List(Meta)))
}

pub type PresenceEvent {
  State(Presence)
  Diff(joins: Presence, leaves: Presence)
}

pub type PresenceError {
  InvalidState
  InvalidDiff
}

pub fn new() -> Presence {
  Presence(dict.new())
}

pub fn decode_state(payload: Dynamic) -> Result(PresenceEvent, PresenceError) {
  decode.run(payload, presence_decoder())
  |> result.map(fn(entries) { State(Presence(entries)) })
  |> result.replace_error(InvalidState)
}

pub fn decode_diff(payload: Dynamic) -> Result(PresenceEvent, PresenceError) {
  let decoder = {
    use joins <- decode.field("joins", presence_decoder())
    use leaves <- decode.field("leaves", presence_decoder())
    decode.success(Diff(Presence(joins), Presence(leaves)))
  }

  decode.run(payload, decoder)
  |> result.replace_error(InvalidDiff)
}

pub fn update(
  presence: Presence,
  event: PresenceEvent,
) -> Result(Presence, PresenceError) {
  let Presence(current) = presence

  case event {
    State(state) -> Ok(state)
    Diff(Presence(joins), Presence(leaves)) -> {
      let with_joins =
        joins
        |> dict.to_list
        |> list.fold(current, fn(entries, joined) {
          let #(key, metas) = joined
          let existing = dict.get(entries, key) |> result.unwrap([])
          dict.insert(entries, key, merge_metas(existing, metas))
        })

      let updated =
        leaves
        |> dict.to_list
        |> list.fold(with_joins, fn(entries, left) {
          let #(key, metas) = left
          let leaving_refs = list.map(metas, fn(meta) { meta.phx_ref })
          let remaining =
            dict.get(entries, key)
            |> result.unwrap([])
            |> list.filter(fn(meta) {
              !list.contains(leaving_refs, meta.phx_ref)
            })

          case remaining {
            [] -> dict.delete(entries, key)
            _ -> dict.insert(entries, key, remaining)
          }
        })

      Ok(Presence(updated))
    }
  }
}

pub fn present_users(presence: Presence) -> List(PresentUser) {
  let Presence(entries) = presence

  entries
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    let #(id, metas) = entry
    case metas {
      [meta, ..] ->
        Ok(PresentUser(id: id, name: meta.name, avatar_url: meta.avatar_url))
      [] -> Error(Nil)
    }
  })
  |> list.sort(by: fn(first, second) {
    case string.compare(first.name, second.name) {
      order.Eq -> string.compare(first.id, second.id)
      order -> order
    }
  })
}

fn presence_decoder() -> decode.Decoder(Dict(String, List(Meta))) {
  decode.dict(decode.string, {
    use metas <- decode.field("metas", decode.list(meta_decoder()))
    decode.success(metas)
  })
}

fn meta_decoder() -> decode.Decoder(Meta) {
  use name <- decode.field("name", decode.string)
  use avatar_url <- decode.field("avatar_url", decode.string)
  use phx_ref <- decode.field("phx_ref", decode.string)
  decode.success(Meta(name:, avatar_url:, phx_ref:))
}

fn merge_metas(existing: List(Meta), joined: List(Meta)) -> List(Meta) {
  list.fold(joined, existing, fn(metas, meta) {
    case list.any(metas, fn(existing) { existing.phx_ref == meta.phx_ref }) {
      True -> metas
      False -> [meta, ..metas]
    }
  })
}
