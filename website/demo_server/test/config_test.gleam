import beryl_demo/config
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn parses_comma_separated_origins_test() {
  config.parse_origins("https://beryl.tylerbutler.com,http://127.0.0.1:4321")
  |> should.equal(["https://beryl.tylerbutler.com", "http://127.0.0.1:4321"])
}

pub fn default_config_is_locked_to_documentation_origins_test() {
  config.default().allowed_origins
  |> should.equal([
    "https://beryl.tylerbutler.com",
    "http://127.0.0.1:4321",
    "http://localhost:4321",
  ])
}

pub fn default_session_ttl_is_ten_minutes_test() {
  config.default().session_ttl_ms
  |> should.equal(600_000)
}
