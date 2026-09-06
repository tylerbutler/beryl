import beryl
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import cursor/app as cursor_app
import cursor/router
import envoy
import example_helper/session_presence
import example_helper/static
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/static_supervisor
import gleam/result
import mist

pub fn main() -> Nil {
  let assert Ok(static_directory) = static.priv_static("cursor")
  let presence_tracker = session_presence.start()
  let context = cursor_app.Context(presence: presence_tracker)

  // The frame limit covers every pre-decode frame and sits modestly above
  // the decoded cursor-event limit to account for joins and malformed data.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 35, burst: 70)
    |> beryl.with_message_rate(per_second: 30, burst: 60)

  let assert Ok(#(channels, beryl_specification)) =
    beryl.child_spec(
      config,
      init: cursor_app.cursor_rooms_init,
      update: cursor_app.cursor_rooms_update(context),
    )
  session_presence.configure(presence_tracker, channels)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_specification)
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
  let context_router =
    router.Context(channels:, base_path: "", static_directory:)

  let assert Ok(_) =
    fn(http_request) {
      mist_transport.upgrade(
        http_request,
        channels,
        server.default_config("/socket/websocket"),
        fn() { router.handle_request(http_request, context_router) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
