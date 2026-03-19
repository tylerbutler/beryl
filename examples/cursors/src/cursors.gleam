import beryl
import beryl/presence
import cursors/adapter
import cursors/cursor_channel
import cursors/router
import gleam/erlang/process
import gleam/io
import mist
import wisp

pub fn main() {
  wisp.configure_logger()

  // Start beryl channels with rate limiting for cursor events
  let config =
    beryl.default_config()
    |> beryl.with_message_rate(per_second: 30, burst: 60)

  let assert Ok(channels) = beryl.start(config)

  // Start presence tracking
  let presence_config = presence.default_config("node1")
  let assert Ok(presence_actor) = presence.start(presence_config)

  // Register the cursor channel handler
  let handler = cursor_channel.new_handler(channels, presence_actor)
  let assert Ok(_) = beryl.register(channels, "cursor:*", handler)

  io.println("🖱️  Collaborative Cursors Demo")
  io.println("   Open http://localhost:8000 in multiple browser tabs")
  io.println("")

  // Start the HTTP server
  let secret_key_base = wisp.random_string(64)
  let ctx = router.Context(channels:, presence: presence_actor)

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> adapter.handler(secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}
