import beryl
import beryl/channel
import beryl/transport/server
import beryl/wire
import beryl_mist
import example_helper/static
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor
import lustre_presence/auth
import lustre_presence/dashboard
import lustre_presence/router
import mist

pub fn main() -> Nil {
  let secret = auth.new_secret()
  let assert Ok(static_directory) = static.priv_static("lustre_presence")
  let assert Ok(#(channels, channels_specification)) =
    channel.child_spec(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_frame_rate(per_second: 20, burst: 40)
        |> beryl.with_message_rate(per_second: 10, burst: 20)
        |> beryl.with_join_rate(per_second: 2, burst: 4)
        |> beryl.with_connection_rate_per_ip(per_second: 5, burst: 10)
        |> beryl.with_max_connections_per_ip(20)
        |> beryl.with_max_connections(200),
      handlers: [dashboard.channel()],
    )
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(channels_specification)
    |> static_supervisor.start()

  let router_context = router.Context(secret:, static_directory:)
  let transport_config =
    server.default_config("/socket/websocket")
    |> server.with_on_connect(fn(http_request) {
      case auth.authenticate_request(http_request, secret) {
        Ok(user) -> Ok(auth.metadata(user))
        Error(Nil) -> Error(server.ConnectRejected)
      }
    })

  let assert Ok(_) =
    fn(http_request) {
      beryl_mist.upgrade(http_request, channels, transport_config, fn() {
        router.handle_request(http_request, router_context)
      })
    }
    |> mist.new
    |> mist.port(8002)
    |> mist.start

  io.println("beryl Lustre presence example")
  io.println("Open http://localhost:8002")
  process.sleep_forever()
}
