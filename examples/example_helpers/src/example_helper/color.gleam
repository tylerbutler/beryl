//// Tiny color helpers used by the example apps for distinguishing users
//// at a glance — not intended for general-purpose use.

import gleam/int
import gleam/list

/// Generate a deterministic pastel HSL color string from a seed.
///
/// Different seeds produce visually distinct hues; the same seed always
/// produces the same color, so a presence list rendered twice in the same
/// session keeps user colors stable.
pub fn pastel_for(seed: String) -> String {
  let hue = charcode_sum(seed) % 360
  "hsl(" <> int.to_string(hue) <> ", 70%, 65%)"
}

fn charcode_sum(value: String) -> Int {
  value
  |> string_to_codepoints
  |> list.fold(0, fn(accumulator, codepoint) { accumulator + codepoint })
}

@external(erlang, "example_helpers_ffi", "string_to_codepoints")
fn string_to_codepoints(value: String) -> List(Int)
