import beryl
import beryl/group
import beryl/presence
import beryl/wire
import beryl_mist as mist_transport
import chatrooms/app as chat_app
import chatrooms/router
import gleam/erlang/process
import gleam/http/request
import gleam/io
import gleam/list
import gleam/result
import mist

pub fn main() {
  // Start presence tracking.
  let presence_config = presence.default_config("node1")
  let assert Ok(presence_actor) = presence.start(presence_config)

  // Start groups and create default room group.
  let assert Ok(groups) = group.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")

  // Dependencies the chat logic reads (presence writes flow through effects).
  let ctx = chat_app.Ctx(presence: presence_actor, groups: groups)

  // Rate limiting matches the previous channel-module deployment; the
  // presence handle is required for the app's presence effects to apply.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_channel_rate(per_second: 10, burst: 20)
    |> beryl.with_presence_handle(presence_actor)

  let assert Ok(channels) =
    beryl.start_app(
      config,
      init: chat_app.standalone_init,
      update: fn(model, ev) { chat_app.standalone_update(ctx, model, ev) },
    )

  io.println("💬 Chat Rooms Demo")
  io.println("   Open http://localhost:8001?token=beryl-demo")
  io.println("")

  // Start the HTTP server. A pre-upgrade token gate rejects connections
  // without the demo token before the WebSocket handshake; accepted
  // connections carry no extra metadata (`Ok([])`).
  let ctx_router =
    router.Context(channels:, presence: presence_actor, groups:, base_path: "")
  let ws_config =
    mist_transport.default_config("/socket/websocket")
    |> mist_transport.with_on_connect(fn(req) {
      case get_query_param(req, "token") {
        Ok("beryl-demo") -> Ok([])
        _ -> Error(mist_transport.ConnectRejected)
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
  case request.get_query(req) {
    Ok(params) ->
      list.find(params, fn(pair) { pair.0 == name })
      |> result.map(fn(pair) { pair.1 })
    Error(_) -> Error(Nil)
  }
}
