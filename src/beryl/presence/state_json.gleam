//// State JSON - Serialization and deserialization for the presence CRDT State
////
//// Provides JSON encoding and decoding of the CRDT State type for
//// cross-node replication via PubSub.

import beryl/presence/state.{
  type Entry, type ReplicaStatus, type State, type Tag, Down, Entry, State, Tag,
  Up,
}
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
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

fn state_decoder() -> decode.Decoder(State) {
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
    #("meta", entry.meta),
  ])
}

fn entry_decoder() -> decode.Decoder(Entry) {
  use topic <- decode.field("topic", decode.string)
  use key <- decode.field("key", decode.string)
  use pid <- decode.field("pid", decode.string)
  use meta <- decode.field("meta", decode.dynamic)
  decode.success(Entry(
    topic: topic,
    key: key,
    pid: pid,
    meta: dynamic_to_json(meta),
  ))
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

/// Convert a Dynamic value (from JSON decoding) back to json.Json.
/// Handles strings, ints, floats, bools, null, lists, and objects.
fn dynamic_to_json(value: decode.Dynamic) -> json.Json {
  case decode.run(value, decode.string) {
    Ok(s) -> json.string(s)
    Error(_) ->
      case decode.run(value, decode.int) {
        Ok(i) -> json.int(i)
        Error(_) ->
          case decode.run(value, decode.float) {
            Ok(f) -> json.float(f)
            Error(_) ->
              case decode.run(value, decode.bool) {
                Ok(b) -> json.bool(b)
                Error(_) -> dynamic_to_json_complex(value)
              }
          }
      }
  }
}

fn dynamic_to_json_complex(value: decode.Dynamic) -> json.Json {
  case dynamic.classify(value) {
    "Nil" -> json.null()
    "Atom" -> json.null()
    "List" ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> json.preprocessed_array(list.map(items, dynamic_to_json))
        Error(_) -> json.null()
      }
    _ ->
      case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
        Ok(d) -> {
          let pairs =
            d
            |> dict.to_list
            |> list.map(fn(pair) { #(pair.0, dynamic_to_json(pair.1)) })
          json.object(pairs)
        }
        Error(_) -> json.null()
      }
  }
}
