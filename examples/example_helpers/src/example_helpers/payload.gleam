//// Tiny JSON-payload accessors used by the example apps. These are
//// deliberately permissive (returning defaults on missing/wrong-type fields)
//// because example UIs would rather render "Anonymous" than crash; real
//// applications should validate and reject malformed payloads instead.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
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
