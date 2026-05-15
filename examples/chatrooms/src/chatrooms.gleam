import beryl
import beryl/group
import beryl/presence
import beryl/transport/mist as mist_transport
import beryl/wire
import chatrooms/chat_channel
import chatrooms/router
import gleam/erlang/process
import gleam/http/request
import gleam/io
import gleam/list
import gleam/result
import mist

pub fn main() {
  // Start beryl channels with rate limiting
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_channel_rate(per_second: 10, burst: 20)

  let assert Ok(channels) = beryl.start(config)

  // Start presence tracking
  let presence_config = presence.default_config("node1")
  let assert Ok(presence_actor) = presence.start(presence_config)

  // Start groups and create default room group
  let assert Ok(groups) = group.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")

  // Register the chat channel handler for room:* topics
  let handler = chat_channel.new_handler(channels, presence_actor, groups)
  let assert Ok(_) = beryl.register(channels, "room:*", handler)

  io.println("💬 Chat Rooms Demo")
  io.println("   Open http://localhost:8001?token=beryl-demo")
  io.println("")

  // Start the HTTP server
  let ctx = router.Context(channels:, presence: presence_actor, groups:)
  let ws_config =
    mist_transport.default_config("/socket/websocket")
    |> mist_transport.with_on_connect(fn(req) {
      case get_query_param(req, "token") {
        Ok("beryl-demo") -> Ok(Nil)
        _ -> Error(Nil)
      }
    })

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(req, channels.coordinator, ws_config, fn() {
        router.handle_request(req, ctx)
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
