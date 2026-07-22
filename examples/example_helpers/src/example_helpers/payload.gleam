//// Tiny JSON-payload accessors used by the example channels. These are
//// deliberately permissive (returning defaults on missing/wrong-type fields)
//// because example UIs would rather render "Anonymous" than crash; real
//// applications should validate and reject malformed payloads instead.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode

/// Read a string-valued field from a channel payload, falling back to
/// `default` if the field is missing, not a string, or the payload isn't
/// a dict.
pub fn string_or(
  payload: Dynamic,
  field_name: String,
  default: String,
) -> String {
  let decoder = {
    use value <- decode.field(field_name, decode.string)
    decode.success(value)
  }
  case decode.run(payload, decoder) {
    Ok(value) -> value
    Error(_) -> default
  }
}
