//// Entrypoint for the beryl presence demo service.
////
//// Reads configuration from the environment, starts the composed listener,
//// and blocks the process forever so the OTP supervisor keeps running.

import beryl_demo/config
import beryl_demo/server
import gleam/erlang/process

pub fn main() {
  let service_config = config.from_env()
  let assert Ok(_) =
    server.start(
      service_config,
      server.AllowOrigins(service_config.allowed_origins),
    )
  process.sleep_forever()
}
