import beryl
import beryl/channel
import beryl/group
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import chatroom/app as chat_app
import chatroom/router
import example_helper/broadcast_hub
import example_helper/session_presence
import example_helper/static
import gleam/erlang/process
import gleam/http/request
import gleam/io
import gleam/list
import gleam/otp/static_supervisor
import gleam/result
import mist

pub fn main() -> Nil {
  let assert Ok(static_directory) = static.priv_static("chatroom")
  let presence_tracker = session_presence.start()

  let #(groups, groups_specification) = group.child_spec()
  let assert Ok(hub) = broadcast_hub.start()

  let context =
    chat_app.Context(presence: presence_tracker, groups: groups, hub: hub)

  // Rate limiting matches the previous channel-module deployment. The frame
  // limit covers every pre-decode frame and sits modestly above the decoded
  // message limit to account for joins and malformed data.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 35, burst: 70)
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_channel_rate(per_second: 10, burst: 20)

  let assert Ok(#(channels, beryl_specification)) =
    channel.child_spec(config, handlers: chat_app.handlers(context))
  session_presence.configure(presence_tracker, channels)
  broadcast_hub.bind(hub, channels)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(groups_specification)
    |> static_supervisor.add(beryl_specification)
    |> static_supervisor.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")

  io.println("💬 Chat Rooms Demo")
  io.println("   Open http://localhost:8001?token=beryl-demo")
  io.println("")

  // Start the HTTP server. A pre-upgrade token gate rejects connections
  // without the demo token before the WebSocket handshake; accepted
  // connections carry no extra metadata (`Ok([])`).
  let context_router =
    router.Context(
      channels:,
      presence: presence_tracker,
      groups:,
      base_path: "",
      static_directory:,
    )
  let ws_config =
    server.default_config("/socket/websocket")
    |> server.with_on_connect(fn(http_request) {
      case get_query_param(http_request, "token") {
        Ok("beryl-demo") -> Ok([])
        Error(_) | Ok(_) -> Error(server.ConnectRejected)
      }
    })

  let assert Ok(_) =
    fn(http_request) {
      mist_transport.upgrade(http_request, channels, ws_config, fn() {
        router.handle_request(http_request, context_router)
      })
    }
    |> mist.new
    |> mist.port(8001)
    |> mist.start

  process.sleep_forever()
}

fn get_query_param(
  http_request: request.Request(mist.Connection),
  name: String,
) -> Result(String, Nil) {
  request.get_query(http_request)
  |> result.try(list.key_find(_, name))
}
