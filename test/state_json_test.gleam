import beryl/presence/state
import beryl/presence/state_json
import gleam/dict
import gleam/json
import gleam/list
import gleam/set
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ── Serialization roundtrip tests ───────────────────────────────────

pub fn roundtrip_empty_state_test() {
  let s = state.new("node1")
  let json_str = state_json.encode_to_string(s)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  decoded.replica |> should.equal("node1")
  dict.size(decoded.context) |> should.equal(0)
  dict.size(decoded.clouds) |> should.equal(0)
  dict.size(decoded.values) |> should.equal(0)
  case dict.get(decoded.replicas, "node1") {
    Ok(state.Up) -> Nil
    _ -> should.fail()
  }
}

pub fn roundtrip_state_with_entries_test() {
  let s = state.new("node1")
  let s =
    state.join(
      s,
      "pid1",
      "room:lobby",
      "user:alice",
      json.object([#("status", json.string("online"))]),
    )
  let s =
    state.join(
      s,
      "pid2",
      "room:lobby",
      "user:bob",
      json.object([#("device", json.string("mobile"))]),
    )

  let json_str = state_json.encode_to_string(s)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  decoded.replica |> should.equal("node1")
  dict.size(decoded.values) |> should.equal(2)

  case dict.get(decoded.context, "node1") {
    Ok(2) -> Nil
    _ -> should.fail()
  }
}

pub fn roundtrip_state_with_multiple_replicas_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "lobby", "alice", json.null())

  let b = state.new("node_b")
  let b = state.join(b, "p2", "lobby", "bob", json.null())

  let #(merged, _) = state.merge(a, b)

  let json_str = state_json.encode_to_string(merged)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  decoded.replica |> should.equal("node_a")
  dict.size(decoded.values) |> should.equal(2)

  case dict.get(decoded.context, "node_a") {
    Ok(1) -> Nil
    _ -> should.fail()
  }
  case dict.get(decoded.context, "node_b") {
    Ok(1) -> Nil
    _ -> should.fail()
  }
}

pub fn roundtrip_state_with_replica_down_test() {
  let a = state.new("node_a")
  let b = state.new("node_b")
  let b = state.join(b, "p1", "lobby", "bob", json.null())

  let #(a, _) = state.merge(a, b)
  let #(a, _) = state.replica_down(a, "node_b")

  let json_str = state_json.encode_to_string(a)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  case dict.get(decoded.replicas, "node_b") {
    Ok(state.Down) -> Nil
    _ -> should.fail()
  }
}

pub fn roundtrip_preserves_merge_semantics_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "lobby", "alice", json.null())

  let b = state.new("node_b")
  let b = state.join(b, "p2", "lobby", "bob", json.null())

  let json_str = state_json.encode_to_string(a)
  let assert Ok(a_roundtripped) = state_json.decode_from_string(json_str)

  let #(merged, diff) = state.merge(a_roundtripped, b)

  state.get_by_topic(merged, "lobby")
  |> list.length
  |> should.equal(2)

  case dict.get(diff.joins, "lobby") {
    Ok(joins) -> list.length(joins) |> should.equal(1)
    Error(_) -> should.fail()
  }
}

pub fn roundtrip_state_with_clouds_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "lobby", "alice", json.null())
  let a = state.join(a, "p2", "lobby", "bob", json.null())

  let json_str = state_json.encode_to_string(a)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  // Sequential joins produce fully-compacted context, no clouds
  dict.to_list(decoded.clouds)
  |> should.equal(dict.to_list(a.clouds))
}

pub fn roundtrip_with_json_meta_test() {
  // Test that metadata survives roundtrip (key ordering may differ)
  let meta =
    json.object([
      #("name", json.string("Alice")),
      #("age", json.int(30)),
      #("active", json.bool(True)),
    ])

  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "user:alice", meta)

  let json_str = state_json.encode_to_string(s)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  // Verify the decoded state still has 1 entry
  dict.size(decoded.values) |> should.equal(1)

  // Verify the re-encoded state produces valid JSON by doing another roundtrip
  let re_encoded = state_json.encode_to_string(decoded)
  let assert Ok(decoded2) = state_json.decode_from_string(re_encoded)
  dict.size(decoded2.values) |> should.equal(1)
}

pub fn roundtrip_preserves_metadata_values_test() {
  let meta =
    json.object([
      #("name", json.string("Alice")),
      #("age", json.int(30)),
      #("pi", json.float(3.14)),
      #("active", json.bool(True)),
      #("tags", json.array(["admin", "user"], json.string)),
      #("nested", json.object([#("inner", json.string("value"))])),
    ])

  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "user:alice", meta)

  // Roundtrip once
  let json_str = state_json.encode_to_string(s)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  // Roundtrip twice — the second encode should be stable
  let re_encoded = state_json.encode_to_string(decoded)
  let assert Ok(decoded2) = state_json.decode_from_string(re_encoded)
  let re_encoded2 = state_json.encode_to_string(decoded2)

  // Stability check: second roundtrip produces identical JSON
  re_encoded2 |> should.equal(re_encoded)
}

pub fn decode_invalid_json_returns_error_test() {
  let result = state_json.decode_from_string("not json")
  should.be_error(result)
}

pub fn decode_missing_fields_returns_error_test() {
  let result = state_json.decode_from_string("{\"replica\": \"node1\"}")
  should.be_error(result)
}

pub fn serialize_deserialize_merge_converges_test() {
  let a = state.new("node_a")
  let a = state.join(a, "p1", "lobby", "alice", json.null())

  let b = state.new("node_b")
  let b = state.join(b, "p2", "lobby", "bob", json.null())

  let a_json = state_json.encode_to_string(a)
  let b_json = state_json.encode_to_string(b)

  let assert Ok(a_from_json) = state_json.decode_from_string(a_json)
  let assert Ok(b_from_json) = state_json.decode_from_string(b_json)

  let #(a_merged, _) = state.merge(a, b_from_json)
  let #(b_merged, _) = state.merge(b, a_from_json)

  state.get_by_topic(a_merged, "lobby")
  |> set.from_list
  |> set.size
  |> should.equal(2)

  state.get_by_topic(b_merged, "lobby")
  |> set.from_list
  |> set.size
  |> should.equal(2)
}

pub fn roundtrip_null_meta_test() {
  let s = state.new("node1")
  let s = state.join(s, "pid1", "room:lobby", "user:alice", json.null())

  let json_str = state_json.encode_to_string(s)
  let assert Ok(decoded) = state_json.decode_from_string(json_str)

  // Roundtrip again to verify null meta is properly handled
  let re_encoded = state_json.encode_to_string(decoded)
  let assert Ok(_decoded2) = state_json.decode_from_string(re_encoded)
  // No crash = success
  Nil
}
