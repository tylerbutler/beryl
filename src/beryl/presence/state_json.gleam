//// State JSON - compatibility facade over lattice_presence/state_json

import beryl/presence/state
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import lattice_presence/state_json as lattice_json

const max_meta_depth = 64

/// Encode a CRDT State to JSON
pub fn encode(s: state.State) -> json.Json {
  lattice_json.to_json(s)
}

/// Encode a State to a JSON string
pub fn encode_to_string(s: state.State) -> String {
  lattice_json.to_json_string(s)
}

/// Decode a JSON string into a State
pub fn decode_from_string(
  json_string: String,
) -> Result(state.State, json.DecodeError) {
  json.parse(from: json_string, using: state_decoder())
}

/// Decoder for the CRDT State type. Used by `decode_from_string` and
/// available for embedding in larger decoders (e.g. sync envelope parsing).
pub fn state_decoder() -> decode.Decoder(state.State) {
  decode.dynamic
  |> decode.then(fn(value) {
    case has_legacy_replicas_field(value) {
      True -> run_state_decoder(value, legacy_state_decoder())
      False -> run_state_decoder(value, lattice_json.decoder())
    }
  })
}

fn has_legacy_replicas_field(value: decode.Dynamic) -> Bool {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) ->
      case dict.get(fields, "replicas") {
        Ok(_) -> True
        Error(_) -> False
      }
    Error(_) -> False
  }
}

fn run_state_decoder(
  value: decode.Dynamic,
  decoder: decode.Decoder(state.State),
) -> decode.Decoder(state.State) {
  case decode.run(value, decoder) {
    Ok(s) -> decode.success(s)
    Error(_) -> decode.failure(state.new(""), "valid presence state")
  }
}

fn legacy_state_decoder() -> decode.Decoder(state.State) {
  legacy_state_json_decoder()
  |> decode.then(fn(legacy_json) {
    case lattice_json.from_json(json.to_string(legacy_json)) {
      Ok(s) -> decode.success(s)
      Error(_) -> decode.failure(state.new(""), "valid legacy presence state")
    }
  })
}

fn legacy_state_json_decoder() -> decode.Decoder(json.Json) {
  use replica <- decode.field("replica", decode.string)
  use context <- decode.field("context", context_json_decoder())
  use clouds <- decode.field("clouds", clouds_json_decoder())
  use values <- decode.field("values", values_json_decoder())
  use _replicas <- decode.field("replicas", replicas_decoder())
  decode.success(
    json.object([
      #("replica", json.string(replica)),
      #("context", context),
      #("clouds", clouds),
      #("values", values),
    ]),
  )
}

fn replicas_decoder() -> decode.Decoder(Nil) {
  decode.dict(decode.string, decode.string)
  |> decode.then(fn(replicas) {
    case replicas_all_up(replicas) {
      True -> decode.success(Nil)
      False -> decode.failure(Nil, "legacy replicas all up")
    }
  })
}

fn replicas_all_up(replicas: dict.Dict(String, String)) -> Bool {
  dict.fold(replicas, True, fn(valid, _, status) { valid && status == "up" })
}

fn context_json_decoder() -> decode.Decoder(json.Json) {
  decode.dict(decode.string, decode.int)
  |> decode.map(fn(context) {
    context
    |> dict.to_list
    |> list.map(fn(kv) { #(kv.0, json.int(kv.1)) })
    |> json.object
  })
}

fn clouds_json_decoder() -> decode.Decoder(json.Json) {
  decode.dict(decode.string, decode.list(decode.int))
  |> decode.map(fn(clouds) {
    clouds
    |> dict.to_list
    |> list.map(fn(kv) { #(kv.0, json.array(kv.1, json.int)) })
    |> json.object
  })
}

fn values_json_decoder() -> decode.Decoder(json.Json) {
  decode.list(value_json_decoder())
  |> decode.map(json.preprocessed_array)
}

fn value_json_decoder() -> decode.Decoder(json.Json) {
  use tag <- decode.field("tag", tag_json_decoder())
  use entry <- decode.field("entry", entry_json_decoder())
  decode.success(json.object([#("tag", tag), #("entry", entry)]))
}

fn tag_json_decoder() -> decode.Decoder(json.Json) {
  use replica <- decode.field("replica", decode.string)
  use clock <- decode.field("clock", decode.int)
  decode.success(
    json.object([
      #("replica", json.string(replica)),
      #("clock", json.int(clock)),
    ]),
  )
}

fn entry_json_decoder() -> decode.Decoder(json.Json) {
  use topic <- decode.field("topic", decode.string)
  use key <- decode.field("key", decode.string)
  use pid <- decode.field("pid", decode.string)
  use meta_string <- decode.field("meta", decode.string)
  case json.parse(from: meta_string, using: json_value_decoder()) {
    Ok(meta) ->
      decode.success(
        json.object([
          #("topic", json.string(topic)),
          #("key", json.string(key)),
          #("pid", json.string(pid)),
          #("meta", meta),
        ]),
      )
    Error(_) -> decode.failure(json.null(), "valid JSON in legacy meta field")
  }
}

fn json_value_decoder() -> decode.Decoder(json.Json) {
  json_value_decoder_at(0)
}

fn json_value_decoder_at(depth: Int) -> decode.Decoder(json.Json) {
  case depth > max_meta_depth {
    True -> decode.failure(json.null(), "metadata depth within limit")
    False -> json_value_decoder_within_limit(depth)
  }
}

fn json_value_decoder_within_limit(depth: Int) -> decode.Decoder(json.Json) {
  decode.one_of(decode.string |> decode.map(json.string), [
    decode.int |> decode.map(json.int),
    decode.float |> decode.map(json.float),
    decode.bool |> decode.map(json.bool),
    decode.optional(decode.string)
      |> decode.then(fn(opt) {
        case opt {
          option.None -> decode.success(json.null())
          option.Some(_) -> decode.failure(json.null(), "null")
        }
      }),
    decode.list(decode.dynamic)
      |> decode.then(fn(items) { json_value_list(items, [], depth + 1) }),
    decode.dict(decode.string, decode.dynamic)
      |> decode.then(fn(d) {
        let pairs = dict.to_list(d)
        json_value_dict(pairs, [], depth + 1)
      }),
  ])
}

fn json_value_list(
  items: List(decode.Dynamic),
  acc: List(json.Json),
  depth: Int,
) -> decode.Decoder(json.Json) {
  case items {
    [] -> decode.success(json.preprocessed_array(list.reverse(acc)))
    [item, ..rest] ->
      case decode.run(item, json_value_decoder_at(depth)) {
        Ok(val) -> json_value_list(rest, [val, ..acc], depth)
        Error(_) -> decode.failure(json.null(), "valid JSON value in array")
      }
  }
}

fn json_value_dict(
  pairs: List(#(String, decode.Dynamic)),
  acc: List(#(String, json.Json)),
  depth: Int,
) -> decode.Decoder(json.Json) {
  case pairs {
    [] -> decode.success(json.object(list.reverse(acc)))
    [#(key, value), ..rest] ->
      case decode.run(value, json_value_decoder_at(depth)) {
        Ok(val) -> json_value_dict(rest, [#(key, val), ..acc], depth)
        Error(_) -> decode.failure(json.null(), "valid JSON value in object")
      }
  }
}
