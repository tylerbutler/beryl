import beryl
import beryl/wire
import heirloom

pub fn main() -> Nil {
  let assert "consumer heirloom" = heirloom.marker()
  let _config = beryl.config(wire.phoenix_codec())
  Nil
}
