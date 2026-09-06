//// Showcase: all three example channels on one socket, composed with
//// `beryl/channel`.
////
//// Each example's topic namespace is a channel handler here — `cursor:*`,
//// `room:*`, and `document:` — and the layer routes every socket event
//// to the handler that owns its topic. There is no socket-wide model, no
//// message union, and no hand-written router: a channel keeps its own
//// private state per joined topic and the layer prunes it when the topic
//// closes.
////
//// The standalone `cursors`, `chatrooms`, and `collab_docs` servers stay
//// on raw `beryl.child_spec` dispatch on purpose: each serves a single
//// topic namespace, which is the case the core API already handles well.
//// This app is the multi-topic case the channel layer exists for.

import beryl
import beryl/channel
import beryl/group
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import chatroom/router as chatroom_router
import collab_document/auth as document_auth
import collab_document/document_store
import collab_document/router as document_router
import cursor/router as cursor_router
import envoy
import example_helper/broadcast_hub as hub
import example_helper/session_presence
import example_helper/static
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/static_supervisor
import gleam/result
import mist
import showcase/channel/cursor as cursor_channel
import showcase/channel/document as document_channel
import showcase/channel/room as room_channel
import showcase/router

/// Everything the showcase channels read. Assembled in `main` and passed
/// to `handlers`, which is also what the tests register, so the deployed
/// table and the tested table cannot drift.
pub type Dependencies {
  Dependencies(
    presence: session_presence.Tracker,
    groups: group.Groups,
    store: document_store.Store,
    secret: BitArray,
    hub: hub.Hub,
  )
}

/// The showcase's channel table: one handler per topic namespace plus the
/// read-only lobby mounted by the standalone chat app.
///
/// Handlers are consulted in list order and the first matching pattern
/// owns the topic; these patterns do not overlap, so the order is
/// documentation rather than resolution.
pub fn handlers(dependencies: Dependencies) -> List(channel.Handler) {
  [
    lobby(),
    cursor_channel.channel(cursor_channel.Context(dependencies.presence)),
    room_channel.channel(room_channel.Context(
      presence: dependencies.presence,
      groups: dependencies.groups,
      hub: dependencies.hub,
    )),
    document_channel.channel(document_channel.Context(
      store: dependencies.store,
      secret: dependencies.secret,
    )),
  ]
}

fn lobby() -> channel.Handler {
  channel.handler("lobby", fn(_context) { channel.accept(Nil) })
}

pub fn main() -> Nil {
  let assert Ok(cursor_static_directory) = static.priv_static("cursor")
  let assert Ok(chatroom_static_directory) = static.priv_static("chatroom")
  let assert Ok(document_static_directory) =
    static.priv_static("collab_document")
  // Shared example-local session presence. Mutations and capacity reads are
  // synchronous ETS operations; snapshots publish asynchronously.
  let presence_tracker = session_presence.start()

  // Chatrooms-specific state.
  let #(groups, groups_specification) = group.child_spec()

  // collab_docs-specific state.
  let document_secret = document_auth.new_secret()
  let assert Ok(document_store_process) = document_store.start()

  // The showcase's broadcast hub: bound to the running system below, and
  // used for the one announcement no channel's own topic can carry (the
  // `lobby` room list).
  let assert Ok(hub) = hub.start()

  // Per-topic-pattern rate limits replace the old single global
  // channel-rate compromise: cursors stream fast, chat and docs do not.
  // The frame budget sits modestly above the decoded-message budget to
  // account for joins and malformed frames.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 35, burst: 70)
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_topic_rate(pattern: "cursor:*", per_second: 30, burst: 60)
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 10, burst: 20)
    |> beryl.with_topic_rate(pattern: "document:*:*", per_second: 10, burst: 20)

  let dependencies =
    Dependencies(
      presence: presence_tracker,
      groups: groups,
      store: document_store_process,
      secret: document_secret,
      hub: hub,
    )

  let assert Ok(#(channels, beryl_specification)) =
    channel.child_spec(config, handlers: handlers(dependencies))

  session_presence.configure(presence_tracker, channels)
  hub.bind(hub, channels)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(groups_specification)
    |> static_supervisor.add(beryl_specification)
    |> static_supervisor.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")

  // Build per-example contexts pinned to their URL prefix.
  let cursor_context =
    cursor_router.Context(
      channels:,
      base_path: "/cursors",
      static_directory: cursor_static_directory,
    )
  let chatroom_context =
    chatroom_router.Context(
      channels:,
      presence: presence_tracker,
      groups:,
      base_path: "/chat",
      static_directory: chatroom_static_directory,
    )
  let collab_document_context =
    document_router.Context(
      channels:,
      store: document_store_process,
      secret: document_secret,
      base_path: "/docs",
      static_directory: document_static_directory,
    )
  let showcase_context =
    router.Context(
      cursor: cursor_context,
      chatroom: chatroom_context,
      collab_document: collab_document_context,
    )

  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(8000)
  let interface =
    envoy.get("BIND_ADDRESS")
    |> result.unwrap("localhost")

  io.println("✨ beryl examples showcase (beryl/channel)")
  io.println("   Listening on " <> interface <> ":" <> int.to_string(port))
  io.println("")

  // Single WebSocket endpoint at /socket/websocket. No token gate — this
  // is a public demo. Phoenix JS client (new Socket("/socket")) in every
  // example targets this URL out of the box.
  let assert Ok(_) =
    fn(http_request) {
      mist_transport.upgrade(
        http_request,
        channels,
        server.default_config("/socket/websocket"),
        fn() { router.handle_request(http_request, showcase_context) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
