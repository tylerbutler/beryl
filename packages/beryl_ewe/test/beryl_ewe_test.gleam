import vouch

/// Test entrypoint: vouch discovers and runs every `*_test` module in
/// this package.
pub fn main() {
  vouch.main()
}
