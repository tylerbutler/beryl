import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}

@external(javascript, "./local_storage_ffi.mjs", "getItem")
fn get_item_data(key: String) -> Dynamic

@external(javascript, "./local_storage_ffi.mjs", "setItem")
pub fn set_item(key: String, value: String) -> Bool

pub fn get_item(key: String) -> Result(Option(String), Nil) {
  let decoder = {
    use ok <- decode.field("ok", decode.bool)
    use found <- decode.field("found", decode.bool)
    use value <- decode.field("value", decode.string)
    decode.success(#(ok, found, value))
  }

  case decode.run(get_item_data(key), decoder) {
    Ok(#(True, True, value)) -> Ok(Some(value))
    Ok(#(True, False, _)) -> Ok(None)
    _ -> Error(Nil)
  }
}
