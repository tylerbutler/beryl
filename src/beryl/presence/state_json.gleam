//// State JSON - compatibility facade over lattice_presence/state_json

import beryl/presence/state
import gleam/dynamic/decode
import gleam/json
import lattice_presence/state_json as lattice_json

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
  lattice_json.from_json(json_string)
}

/// Decoder for the CRDT State type. Used by `decode_from_string` and
/// available for embedding in larger decoders (e.g. sync envelope parsing).
pub fn state_decoder() -> decode.Decoder(state.State) {
  lattice_json.decoder()
}

/// New lattice_presence-compatible name for callers that prefer it.
pub fn to_json(s: state.State) -> json.Json {
  lattice_json.to_json(s)
}

/// New lattice_presence-compatible name for callers that prefer it.
pub fn to_json_string(s: state.State) -> String {
  lattice_json.to_json_string(s)
}

/// New lattice_presence-compatible name for callers that prefer it.
pub fn from_json(json_string: String) -> Result(state.State, json.DecodeError) {
  lattice_json.from_json(json_string)
}

/// New lattice_presence-compatible name for callers that prefer it.
pub fn decoder() -> decode.Decoder(state.State) {
  lattice_json.decoder()
}
