import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn scaffold_test() {
  True
  |> should.equal(True)
}
