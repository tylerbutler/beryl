import beryl
import beryl/presence
import beryl/socket/router as topic_router
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import cursors/app as cursors_app
import cursors/router
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/result
import mist

pub fn main() {
  // Start presence tracking.
  let presence_config = presence.default_config("node1")
  let assert Ok(presence_actor) = presence.start(presence_config)

  // Rate limiting for cursor events; the presence handle is required for
  // the app's presence effects to apply. with_frame_rate covers the
  // transport edge (every inbound frame, pre-decode) since
  // with_message_rate alone no longer sheds floods there.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 30, burst: 60)
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_presence_handle(presence_actor)

  let assert Ok(channels) =
    beryl.start(
      config,
      init: topic_router.standalone_init,
      update: cursors_app.standalone_update(),
    )

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

  // Start the HTTP server.
  let ctx_router =
    router.Context(channels:, presence: presence_actor, base_path: "")

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels,
        server.default_config("/socket/websocket"),
        fn() { router.handle_request(req, ctx_router) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
