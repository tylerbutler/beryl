//// Tiny JSON-payload accessors used by the example apps. These are
//// deliberately permissive (returning defaults on missing/wrong-type fields)
//// because example UIs would rather render "Anonymous" than crash; real
//// applications should validate and reject malformed payloads instead.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/result

/// Read a string-valued field from a payload. Errors if the field is
/// missing, not a string, or the payload isn't a dict.
pub fn string_field(
  payload: Dynamic,
  field_name: String,
) -> Result(String, Nil) {
  let decoder = {
    use value <- decode.field(field_name, decode.string)
    decode.success(value)
  }
  decode.run(payload, decoder)
  |> result.replace_error(Nil)
}

/// Read a string-valued field from a payload, falling back to `default` if
/// the field is missing, not a string, or the payload isn't a dict.
pub fn string_or(
  payload: Dynamic,
  field_name: String,
  default: String,
) -> String {
  case string_field(payload, field_name) {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

/// Read a number-valued field from a payload as a `Float`, accepting both
/// JSON floats and ints. Errors if the field is missing, not a number, or
/// the payload isn't a dict.
pub fn float_field(payload: Dynamic, field_name: String) -> Result(Float, Nil) {
  let number =
    decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
  let decoder = {
    use value <- decode.field(field_name, number)
    decode.success(value)
  }
  decode.run(payload, decoder)
  |> result.replace_error(Nil)
}

/// Read a number-valued field from a payload and re-encode it as JSON,
/// falling back to `0.0` when it is missing or not a number. Ints stay ints
/// and floats stay floats on the wire, so relaying a value does not change
/// its JSON type.
pub fn json_number_or_zero(payload: Dynamic, field_name: String) -> Json {
  let number =
    decode.one_of(decode.float |> decode.map(json.float), or: [
      decode.int |> decode.map(json.int),
    ])
  let decoder = {
    use value <- decode.field(field_name, number)
    decode.success(value)
  }
  decode.run(payload, decoder)
  |> result.unwrap(json.float(0.0))
}
