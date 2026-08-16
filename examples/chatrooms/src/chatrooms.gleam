import beryl
import beryl/channel
import beryl/group
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import chatrooms/app as chat_app
import chatrooms/router
import example_helpers/broadcast_hub
import example_helpers/session_presence
import gleam/erlang/process
import gleam/http/request
import gleam/io
import gleam/list
import gleam/otp/static_supervisor
import gleam/result
import mist

pub fn main() {
  let presence_tracker = session_presence.start()

  // Start groups and create default room group.
  let assert Ok(groups) = group.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")
  let assert Ok(hub) = broadcast_hub.start()

  let ctx = chat_app.Ctx(presence: presence_tracker, groups: groups, hub: hub)

  // Rate limiting matches the previous channel-module deployment. The frame
  // limit covers every pre-decode frame and sits modestly above the decoded
  // message limit to account for joins and malformed data.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 35, burst: 70)
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_channel_rate(per_second: 10, burst: 20)

  let assert Ok(#(channels, beryl_spec)) =
    channel.child_spec(config, handlers: chat_app.handlers(ctx))
  session_presence.configure(presence_tracker, channels)
  broadcast_hub.bind(hub, channels)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  io.println("💬 Chat Rooms Demo")
  io.println("   Open http://localhost:8001?token=beryl-demo")
  io.println("")

  // Start the HTTP server. A pre-upgrade token gate rejects connections
  // without the demo token before the WebSocket handshake; accepted
  // connections carry no extra metadata (`Ok([])`).
  let ctx_router =
    router.Context(
      channels:,
      presence: presence_tracker,
      groups:,
      base_path: "",
    )
  let ws_config =
    server.default_config("/socket/websocket")
    |> server.with_on_connect(fn(req) {
      case get_query_param(req, "token") {
        Ok("beryl-demo") -> Ok([])
        _ -> Error(server.ConnectRejected)
      }
    })

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(req, channels, ws_config, fn() {
        router.handle_request(req, ctx_router)
      })
    }
    |> mist.new
    |> mist.port(8001)
    |> mist.start

  process.sleep_forever()
}

fn get_query_param(req, name: String) -> Result(String, Nil) {
  request.get_query(req)
  |> result.try(list.key_find(_, name))
}
