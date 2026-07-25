import beryl
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import cursors/app as cursors_app
import cursors/router
import envoy
import example_helpers/session_presence
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/static_supervisor
import gleam/result
import mist

pub fn main() {
  let presence_tracker = session_presence.start()
  let ctx = cursors_app.Ctx(presence: presence_tracker)

  // Rate limiting for cursor events.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 30, burst: 60)

  let assert Ok(#(channels, beryl_spec)) =
    beryl.child_spec(
      config,
      init: cursors_app.standalone_init,
      update: fn(model, ev) { cursors_app.standalone_update(ctx, model, ev) },
    )
  session_presence.configure(presence_tracker, channels)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

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
  let ctx_router = router.Context(channels:, base_path: "")

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
