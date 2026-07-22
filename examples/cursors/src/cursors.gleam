import beryl
import beryl/presence
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

  // Dependencies the cursor logic reads (presence writes flow through effects).
  let ctx = cursors_app.Ctx(presence: presence_actor)

  // Rate limiting for cursor events; the presence handle is required for
  // the app's presence effects to apply.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_presence_handle(presence_actor)

  let assert Ok(channels) =
    beryl.start_app(
      config,
      init: cursors_app.standalone_init,
      update: fn(model, ev) { cursors_app.standalone_update(ctx, model, ev) },
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
        mist_transport.default_config("/socket/websocket"),
        fn() { router.handle_request(req, ctx_router) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
