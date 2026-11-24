import envoy
import load_test_ewe
import load_test_mist

pub fn main() -> Nil {
  case envoy.get("SERVER") {
    Error(_) | Ok("ewe") -> load_test_ewe.main()
    Ok(_) -> load_test_mist.main()
  }
}
