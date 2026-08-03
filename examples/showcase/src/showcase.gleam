//// Showcase: all three example channels on one socket, composed with
//// `beryl_channels`.
////
//// Each example's topic namespace is a channel handler here — `cursor:*`,
//// `room:*`, and `document:` — and the layer routes every socket event
//// to the handler that owns its topic. There is no socket-wide model, no
//// message union, and no hand-written router: a channel keeps its own
//// private state per joined topic and the layer prunes it when the topic
//// closes.
////
//// The standalone `cursors`, `chatrooms`, and `collab_docs` servers stay
//// on raw `beryl.start` dispatch on purpose: each serves a single topic
//// namespace, which is the case the core API already handles well. This
//// app is the multi-topic case the channel layer exists for.

import beryl
import beryl/group
import beryl/presence
import beryl/transport/server
import beryl/wire
import beryl_channels
import beryl_channels/channel
import beryl_mist as mist_transport
import chatrooms/router as chatrooms_router
import collab_docs/auth as docs_auth
import collab_docs/doc_store
import collab_docs/router as collab_docs_router
import cursors/router as cursors_router
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/result
import mist
import showcase/channels/cursors as cursors_channel
import showcase/channels/documents as documents_channel
import showcase/channels/rooms as rooms_channel
import showcase/hub
import showcase/router

/// Everything the showcase channels read. Assembled in `main` and passed
/// to `handlers`, which is also what the tests register, so the deployed
/// table and the tested table cannot drift.
pub type Deps {
  Deps(
    presence: presence.Presence,
    groups: group.Groups,
    store: doc_store.Store,
    secret: BitArray,
    hub: hub.Hub,
  )
}

/// The showcase's channel table: one handler per topic namespace.
///
/// Handlers are consulted in list order and the first matching pattern
/// owns the topic; these three patterns do not overlap, so the order is
/// documentation rather than resolution. A topic none of them claims —
/// `lobby`, for instance — is refused by the layer.
pub fn handlers(deps: Deps) -> List(channel.Handler) {
  [
    cursors_channel.channel(),
    rooms_channel.channel(rooms_channel.Ctx(
      presence: deps.presence,
      groups: deps.groups,
      hub: deps.hub,
    )),
    documents_channel.channel(documents_channel.Ctx(
      store: deps.store,
      secret: deps.secret,
    )),
  ]
}

pub fn main() {
  // Shared presence actor — each embedded app scopes presence to its own
  // topic namespace, so a single actor is safe.
  let presence_config = presence.default_config("node1")
  let assert Ok(presence_actor) = presence.start(presence_config)

  // Chatrooms-specific state.
  let assert Ok(groups) = group.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")

  // collab_docs-specific state.
  let docs_secret = docs_auth.new_secret()
  let assert Ok(docs_store) = doc_store.start()

  // The showcase's broadcast hub: bound to the running system below, and
  // used for the one announcement no channel's own topic can carry (the
  // `lobby` room list).
  let assert Ok(hub) = hub.start()

  // Per-topic-pattern rate limits replace the old single global
  // channel-rate compromise: cursors stream fast, chat and docs do not.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_topic_rate(pattern: "cursor:*", per_second: 30, burst: 60)
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 10, burst: 20)
    |> beryl.with_topic_rate(pattern: "document:*:*", per_second: 10, burst: 20)
    |> beryl.with_presence_handle(presence_actor)

  let deps =
    Deps(
      presence: presence_actor,
      groups: groups,
      store: docs_store,
      secret: docs_secret,
      hub: hub,
    )

  let assert Ok(channels) =
    beryl_channels.start(config, handlers: handlers(deps))

  // Bound before the listener starts, so no channel can run unbound.
  hub.bind(hub, channels)

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

  io.println("✨ beryl examples showcase (beryl_channels)")
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
        server.default_config("/socket/websocket"),
        fn() { router.handle_request(req, showcase_ctx) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
