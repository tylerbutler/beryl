import unitest

/// Test entrypoint: unitest discovers and runs every `*_test` module in
/// this package.
pub fn main() -> Nil {
  unitest.main()
}
