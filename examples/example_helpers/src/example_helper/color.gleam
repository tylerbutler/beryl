//// Tiny color helpers used by the example apps for distinguishing users
//// at a glance — not intended for general-purpose use.

import gleam/int
import gleam/list
import gleam/string

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
  |> string.to_utf_codepoints
  |> list.fold(0, fn(accumulator, codepoint) {
    accumulator + string.utf_codepoint_to_int(codepoint)
  })
}
