import beryl
import beryl/presence
import beryl/transport/mist as mist_transport
import beryl/wire
import cursors/cursor_channel
import cursors/router
import gleam/erlang/process
import gleam/io
import mist

pub fn main() {
  // Start beryl channels with rate limiting for cursor events
  let config =
    beryl.config(wire.phoenix_codec())
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
  let ctx = router.Context(channels:, presence: presence_actor)

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels,
        mist_transport.default_config("/socket/websocket"),
        fn() { router.handle_request(req, ctx) },
      )
    }
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}
