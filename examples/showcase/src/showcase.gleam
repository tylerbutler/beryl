import beryl
import beryl/group
import beryl/presence
import beryl/supervisor
import beryl/wire
import beryl_mist as mist_transport
import chatrooms/chat_channel
import chatrooms/router as chatrooms_router
import collab_docs/auth as docs_auth
import collab_docs/channel as docs_channel
import collab_docs/doc_store
import collab_docs/router as collab_docs_router
import cursors/cursor_channel
import cursors/router as cursors_router
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import mist
import showcase/router

pub fn main() {
  // Single beryl instance, rate-limited using cursors' tighter knobs
  // (cursors emits the most messages per second of the three examples).
  // Shared presence actor — each example's handler scopes presence to its
  // own topic namespace, so a single actor is safe.
  let beryl_config =
    supervisor.config(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_message_rate(per_second: 30, burst: 60)
      |> beryl.with_join_rate(per_second: 5, burst: 10)
      |> beryl.with_channel_rate(per_second: 10, burst: 20),
    )
    |> supervisor.with_presence(presence.default_config("node1"))
    |> supervisor.with_groups()

  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervisor.start(beryl_config))
    |> static_supervisor.start()

  let channels = supervisor.channels(beryl_config)
  let assert Some(presence_actor) = supervisor.presence(beryl_config)

  // Chatrooms-specific state.
  let assert Some(groups) = supervisor.groups(beryl_config)
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")

  // collab_docs-specific state.
  let docs_secret = docs_auth.new_secret()
  let assert Ok(docs_store) = doc_store.start()

  // Register all three handlers on the single channels instance. Topic
  // namespaces (cursor:*, room:*, document:*:*) don't collide.
  let cursors_handler = cursor_channel.new_handler(channels, presence_actor)
  let assert Ok(_) = beryl.register(channels, "cursor:*", cursors_handler)

  let chat_handler = chat_channel.new_handler(channels, presence_actor, groups)
  let assert Ok(_) = beryl.register(channels, "room:*", chat_handler)

  let docs_handler = docs_channel.new_handler(channels, docs_store, docs_secret)
  let assert Ok(_) = beryl.register(channels, "document:*:*", docs_handler)

  // Build per-example contexts pinned to their URL prefix.
  let cursors_ctx =
    cursors_router.Context(
      channels:,
      presence: presence_actor,
      base_path: "/cursors",
    )
  let chatrooms_ctx =
    chatrooms_router.Context(
      channels:,
      presence: presence_actor,
      groups:,
      base_path: "/chat",
    )
  let collab_docs_ctx =
    collab_docs_router.Context(
      channels:,
      store: docs_store,
      secret: docs_secret,
      base_path: "/docs",
    )
  let showcase_ctx =
    router.Context(
      cursors: cursors_ctx,
      chatrooms: chatrooms_ctx,
      collab_docs: collab_docs_ctx,
    )

  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(8000)
  let interface =
    envoy.get("BIND_ADDRESS")
    |> result.unwrap("localhost")

  io.println("✨ beryl examples showcase")
  io.println("   Listening on " <> interface <> ":" <> int.to_string(port))
  io.println("")

  // Single WebSocket endpoint at /socket/websocket. No token gate — this
  // is a public demo. Phoenix JS client (new Socket("/socket")) in every
  // example targets this URL out of the box.
  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels,
        mist_transport.default_config("/socket/websocket"),
        fn() { router.handle_request(req, showcase_ctx) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
