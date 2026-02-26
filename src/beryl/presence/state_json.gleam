//// State JSON - Serialization and deserialization for the presence CRDT State
////
//// Provides JSON encoding and decoding of the CRDT State type for
//// cross-node replication via PubSub.

import beryl/presence/state.{
  type Entry, type ReplicaStatus, type State, type Tag, Down, Entry, State, Tag,
  Up,
}
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/set

/// Encode a CRDT State to JSON
pub fn encode(s: State) -> json.Json {
  json.object([
    #("replica", json.string(s.replica)),
    #("context", encode_context(s.context)),
    #("clouds", encode_clouds(s.clouds)),
    #("values", encode_values(s.values)),
    #("replicas", encode_replicas(s.replicas)),
  ])
}

/// Encode a State to a JSON string
pub fn encode_to_string(s: State) -> String {
  encode(s) |> json.to_string
}

/// Decode a JSON string into a State
pub fn decode_from_string(
  json_string: String,
) -> Result(State, json.DecodeError) {
  json.parse(from: json_string, using: state_decoder())
}

/// Decoder for the CRDT State type. Used by `decode_from_string` and
/// available for embedding in larger decoders (e.g. sync envelope parsing).
pub fn state_decoder() -> decode.Decoder(State) {
  use replica <- decode.field("replica", decode.string)
  use context <- decode.field("context", context_decoder())
  use clouds <- decode.field("clouds", clouds_decoder())
  use values <- decode.field("values", values_decoder())
  use replicas <- decode.field("replicas", replicas_decoder())
  decode.success(State(
    replica: replica,
    context: context,
    clouds: clouds,
    values: values,
    replicas: replicas,
  ))
}

// ── Context (vector clock) ──────────────────────────────────────────

fn encode_context(context: dict.Dict(String, Int)) -> json.Json {
  context
  |> dict.to_list
  |> list.map(fn(kv) { #(kv.0, json.int(kv.1)) })
  |> json.object
}

fn context_decoder() -> decode.Decoder(dict.Dict(String, Int)) {
  decode.dict(decode.string, decode.int)
}

// ── Clouds ──────────────────────────────────────────────────────────

fn encode_clouds(clouds: dict.Dict(String, set.Set(Int))) -> json.Json {
  clouds
  |> dict.to_list
  |> list.map(fn(kv) { #(kv.0, json.array(set.to_list(kv.1), json.int)) })
  |> json.object
}

fn clouds_decoder() -> decode.Decoder(dict.Dict(String, set.Set(Int))) {
  decode.dict(decode.string, decode.list(decode.int))
  |> decode.map(fn(d) {
    dict.map_values(d, fn(_, clocks) { set.from_list(clocks) })
  })
}

// ── Values (Tag -> Entry) ───────────────────────────────────────────

fn encode_tag(tag: Tag) -> json.Json {
  json.object([
    #("replica", json.string(tag.replica)),
    #("clock", json.int(tag.clock)),
  ])
}

fn tag_decoder() -> decode.Decoder(Tag) {
  use replica <- decode.field("replica", decode.string)
  use clock <- decode.field("clock", decode.int)
  decode.success(Tag(replica: replica, clock: clock))
}

fn encode_entry(entry: Entry) -> json.Json {
  json.object([
    #("topic", json.string(entry.topic)),
    #("key", json.string(entry.key)),
    #("pid", json.string(entry.pid)),
    #("meta", json.string(json.to_string(entry.meta))),
  ])
}

fn entry_decoder() -> decode.Decoder(Entry) {
  use topic <- decode.field("topic", decode.string)
  use key <- decode.field("key", decode.string)
  use pid <- decode.field("pid", decode.string)
  use meta_str <- decode.field("meta", decode.string)
  case json.parse(meta_str, json_value_decoder()) {
    Ok(meta) ->
      decode.success(Entry(topic: topic, key: key, pid: pid, meta: meta))
    Error(_) ->
      decode.failure(
        Entry(topic: topic, key: key, pid: pid, meta: json.null()),
        "valid JSON in meta field",
      )
  }
}

fn encode_values(values: dict.Dict(Tag, Entry)) -> json.Json {
  values
  |> dict.to_list
  |> list.map(fn(kv) {
    json.object([
      #("tag", encode_tag(kv.0)),
      #("entry", encode_entry(kv.1)),
    ])
  })
  |> json.preprocessed_array
}

fn values_decoder() -> decode.Decoder(dict.Dict(Tag, Entry)) {
  decode.list({
    use tag <- decode.field("tag", tag_decoder())
    use entry <- decode.field("entry", entry_decoder())
    decode.success(#(tag, entry))
  })
  |> decode.map(dict.from_list)
}

// ── Replicas ────────────────────────────────────────────────────────

fn encode_replica_status(status: ReplicaStatus) -> json.Json {
  case status {
    Up -> json.string("up")
    Down -> json.string("down")
  }
}

fn replica_status_decoder() -> decode.Decoder(ReplicaStatus) {
  decode.string
  |> decode.then(fn(s) {
    case s {
      "up" -> decode.success(Up)
      "down" -> decode.success(Down)
      _ -> decode.failure(Up, "ReplicaStatus")
    }
  })
}

fn encode_replicas(replicas: dict.Dict(String, ReplicaStatus)) -> json.Json {
  replicas
  |> dict.to_list
  |> list.map(fn(kv) { #(kv.0, encode_replica_status(kv.1)) })
  |> json.object
}

fn replicas_decoder() -> decode.Decoder(dict.Dict(String, ReplicaStatus)) {
  decode.dict(decode.string, replica_status_decoder())
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Decoder that reconstructs a json.Json value from parsed JSON.
/// Uses standard decoder combinators instead of BEAM-specific dynamic.classify.
fn json_value_decoder() -> decode.Decoder(json.Json) {
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
      |> decode.then(fn(items) { json_value_list(items, []) }),
    decode.dict(decode.string, decode.dynamic)
      |> decode.then(fn(d) {
        let pairs = dict.to_list(d)
        json_value_dict(pairs, [])
      }),
  ])
}

fn json_value_list(
  items: List(decode.Dynamic),
  acc: List(json.Json),
) -> decode.Decoder(json.Json) {
  case items {
    [] -> decode.success(json.preprocessed_array(list.reverse(acc)))
    [item, ..rest] ->
      case decode.run(item, json_value_decoder()) {
        Ok(val) -> json_value_list(rest, [val, ..acc])
        Error(_) -> decode.failure(json.null(), "valid JSON value in array")
      }
  }
}

fn json_value_dict(
  pairs: List(#(String, decode.Dynamic)),
  acc: List(#(String, json.Json)),
) -> decode.Decoder(json.Json) {
  case pairs {
    [] -> decode.success(json.object(list.reverse(acc)))
    [#(key, value), ..rest] ->
      case decode.run(value, json_value_decoder()) {
        Ok(val) -> json_value_dict(rest, [#(key, val), ..acc])
        Error(_) -> decode.failure(json.null(), "valid JSON value in object")
      }
  }
}
