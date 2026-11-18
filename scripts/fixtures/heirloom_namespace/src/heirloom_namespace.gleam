import beryl
import beryl/wire
import beryl_heirloom
import gleam/option.{Some}
import heirloom

pub fn main() -> Nil {
  let assert "consumer heirloom" = heirloom.marker()
  let _config = beryl.config(wire.phoenix_codec())
  let assert Ok(table) =
    beryl_heirloom.spec("consumer_table", beryl_heirloom.Set)
    |> beryl_heirloom.create
  let assert Ok(Nil) = beryl_heirloom.insert(table, "key", "value")
  let assert Ok(Some("value")) = beryl_heirloom.lookup(table, "key")
  let assert Ok(Nil) = beryl_heirloom.delete(table)
  Nil
}
