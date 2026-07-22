import beryl
import beryl/presence
import beryl/supervisor
import beryl/wire
import beryl_mist as mist_transport
import cursors/cursor_channel
import cursors/router
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import mist

pub fn main() {
  // Configure beryl channels with rate limiting for cursor events, plus
  // presence tracking, then add beryl's child specification to this
  // application's own supervisor.
  let beryl_config =
    supervisor.config(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 30, burst: 60),
    )
    |> supervisor.with_presence(presence.default_config("node1"))

  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervisor.start(beryl_config))
    |> static_supervisor.start()

  let channels = supervisor.channels(beryl_config)
  let assert Some(presence_actor) = supervisor.presence(beryl_config)

  // Register the cursor channel handler
  let handler = cursor_channel.new_handler(channels, presence_actor)
  let assert Ok(_) = beryl.register(channels, "cursor:*", handler)

  // Honor $PORT (Railway/PaaS) and $HOST/$BIND_ADDRESS; fall back to local defaults.
  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(8000)
  let interface =
    envoy.get("BIND_ADDRESS")
    |> result.unwrap("localhost")

  io.println("🖱️  Collaborative Cursors Demo")
  io.println("   Listening on " <> interface <> ":" <> int.to_string(port))
  io.println("")

  // Start the HTTP server
  let ctx = router.Context(channels:, presence: presence_actor, base_path: "")

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
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
