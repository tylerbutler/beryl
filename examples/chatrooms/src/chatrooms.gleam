import beryl
import beryl/group
import beryl/presence
import chatrooms/adapter
import chatrooms/chat_channel
import chatrooms/router
import gleam/erlang/process
import gleam/io
import mist
import wisp

pub fn main() {
  wisp.configure_logger()

  // Start beryl channels with rate limiting
  let config =
    beryl.default_config()
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
  let secret_key_base = wisp.random_string(64)
  let ctx = router.Context(channels:, presence: presence_actor, groups:)

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> adapter.handler(secret_key_base)
    |> mist.new
    |> mist.port(8001)
    |> mist.start

  process.sleep_forever()
}
