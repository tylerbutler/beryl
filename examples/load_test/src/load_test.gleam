import envoy
import load_test_ewe
import load_test_mist

pub fn main() {
  case envoy.get("SERVER") {
    Ok("ewe") -> load_test_ewe.main()
    _ -> load_test_mist.main()
  }
}
